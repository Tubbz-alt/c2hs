--  C->Haskell Compiler: Lexer for CHS Files
--
--  Author : Manuel M. T. Chakravarty
--  Created: 13 August 99
--
--  Version $Revision: 1.12 $ from $Date: 2001/06/20 09:25:13 $
--
--  Copyright (c) [1999..2001] Manuel M. T. Chakravarty
--
--  This file is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This file is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--- DESCRIPTION ---------------------------------------------------------------
--
--  Lexer for CHS files; the tokens are only partially recognised.
--
--- DOCU ----------------------------------------------------------------------
--
--  language: Haskell 98
--
--  * CHS files are assumed to be Haskell 98 files that include C2HS binding
--    hooks.
--
--  * Haskell code is not tokenised, but binding hooks (delimited by `{#'and 
--    `#}') are analysed.  Therefore the lexer operates in two states
--    (realised as two lexer coupled by meta actions) depending on whether
--    Haskell code or a binding hook is currently read.  The lexer reading
--    Haskell code is called `base lexer'; the other one, `binding-hook
--    lexer'.
--
--  * Base lexer:
--
--      haskell -> (inline \\ special)*
--		 | special \\ `"'
--		 | comment
--		 | nested
--		 | hstring
--      special -> `(' | `{' | `-' | `"'
--      ctrl    -> `\n' | `\f' | `\r' | `\t' | `\v'
--
--      inline  -> any \\ ctrl
--      any     -> '\0'..'\255'
--
--    Within the base lexer control codes appear as separate tokens in the
--    token list.
--
--    NOTE: It is important that `(' is an extra lexeme and not added as an
--	    optional component at the end of the first alternative for
--	    `haskell'.  Otherwise, the principle of the longest match will
--	    divide `foo {#' into the tokens `foo {' and `#' instead of `foo '
--	    and `{#'.
--
--    One line comments are handled by
--
--      comment -> `--' (any \\ `\n')* `\n'
--
--    and nested comments by
--
--      nested -> `{-' any* `-}'
--
--    where `any*' may contain _balanced_ occurrences of `{-' and `-}'.
--
--      hstring -> `"' inhstr* `"'
--      inhstr  -> ` '..`\127' \\ `"'
--		 | `\"'
--
--  * On encountering the lexeme `{#', a meta action in the base lexer
--    transfers control to the following binding-hook lexer:
--
--      ident       -> letter (letter | digit | ')*
--      reservedid  -> `as' | `call' | `context' | `deriving' 
--		     | `enum' | `foreign' | `fun' | `get' | `header' | `lib' 
--		     | `newtype' | `pointer' | `prefix' | `set' | `sizeof'
--		     | `stable' | `type' | `underscoreToCase' | `unsafe' 
--		     | `with'
--      reservedsym -> `{#' | `#}' | `{' | `}' | `,' | `.' | `->' | `=' | `*'
--      string      -> `"' instr* `"'
--      instr       -> ` '..`\127' \\ `"'
--      comment	    -> `--' (any \\ `\n')* `\n'
--
--    Control characters, white space, and comments are discarded in the
--    binding-hook lexer.  Nested comments are not allowed in a binding hook.
--
--  * In the binding-hook lexer, the lexeme `#}' transfers control back to the 
--    base lexer.  An occurence of the lexeme `{#' inside the binding-hook
--    lexer triggers an error.  The symbol `{#' is not explcitly represented
--    in the resulting token stream.  However, the occurrence of a token
--    representing one of the reserved identifiers `call', `context', `enum',
--    and `field' marks the start of a binding hook.  Strictly speaking, `#}'
--    need also not occur in the token stream, as the next `haskell' token
--    marks a hook's end.  It is, however, useful for producing accurate error 
--    messages (in case an hook is closed to early) to have a token
--    representing `#}'.
--
--  * The rule `ident' describes Haskell identifiers, but without
--    distinguishing between variable and constructor identifers (ie, those
--    starting with a lowercase and those starting with an uppercase letter).
--    However, we use it also to scan C identifiers; although, strictly
--    speaking, it is too general for them.  In the case of C identifiers,
--    this should not have any impact on the range of descirptions accepted by
--    the tool, as illegal identifier will never occur in a C header file that
--    is accepted by the C lexer.  In the case of Haskell identifiers, a
--    confusion between variable and constructor identifiers will be noted by
--    the Haskell compiler translating the code generated by c2hs.
--
--- TODO ----------------------------------------------------------------------
--
--  * In `haskell', the case of a single `"' (without a matching second one)
--    is caught by an eplicit error raising rule.  This shouldn't be
--    necessary, but for some strange reason, the lexer otherwise hangs when a 
--    single `"' appears in the input.
--
--  * Comments in the "gap" of a string a not yet supported.
--

module CHSLexer (CHSToken(..), lexCHS) 
where 

import List	 ((\\))
import Monad	 (liftM)
import Numeric   (readDec, readOct, readHex)

import Common    (Position, Pos(posOf), incPos, retPos, tabPos)
import Errors    (ErrorLvl(..), Error, makeError)
import UNames	 (NameSupply, Name, names)
import Idents    (Ident, lexemeToIdent, identToLexeme)
import Lexers    (Regexp, Lexer, Action, epsilon, char, (+>), lexaction,
		  lexactionErr, lexmeta, (>|<), (>||<), ctrlLexer, star, plus,
		  quest, alt, string, LexerState, execLexer)

import C2HSState (CST, raise, raiseError, nop, getNameSupply) 


-- token definition
-- ----------------

-- possible tokens (EXPORTED)
--
data CHSToken = CHSTokArrow   Position		-- `->'
	      | CHSTokDot     Position		-- `.'
	      | CHSTokComma   Position		-- `,'
	      | CHSTokEqual   Position		-- `='
	      | CHSTokStar    Position		-- `*'
	      | CHSTokLBrace  Position		-- `{'
	      | CHSTokRBrace  Position		-- `}'
	      | CHSTokLParen  Position		-- `('
	      | CHSTokRParen  Position		-- `)'
	      | CHSTokEndHook Position		-- `#}'
	      | CHSTokAs      Position		-- `as'
	      | CHSTokCall    Position		-- `call'
	      | CHSTokContext Position		-- `context'
	      | CHSTokDerive  Position		-- `deriving'
	      | CHSTokEnum    Position		-- `enum'
	      | CHSTokForeign Position          -- `foreign'
	      | CHSTokFun     Position		-- `fun'
	      | CHSTokGet     Position		-- `get'
	      | CHSTokHeader  Position		-- `header'
	      | CHSTokImport  Position		-- `import'
	      | CHSTokLib     Position		-- `lib'
	      | CHSTokNewtype Position		-- `newtype'
	      | CHSTokPointer Position		-- `pointer'
	      | CHSTokPrefix  Position		-- `prefix'
	      | CHSTokQualif  Position		-- `qualified'
	      | CHSTokSet     Position		-- `set'
	      | CHSTokSizeof  Position		-- `sizeof'
	      | CHSTokStable  Position		-- `stable'
	      | CHSTokType    Position		-- `type'
	      | CHSTok_2Case  Position		-- `underscoreToCase'
	      | CHSTokUnsafe  Position		-- `unsafe'
	      | CHSTokWith    Position		-- `with'
	      | CHSTokString  Position String	-- string 
	      | CHSTokIdent   Position Ident	-- identifier
	      | CHSTokHaskell Position String	-- verbatim Haskell code
	      | CHSTokCtrl    Position Char	-- control code

instance Pos CHSToken where
  posOf (CHSTokArrow   pos  ) = pos
  posOf (CHSTokDot     pos  ) = pos
  posOf (CHSTokComma   pos  ) = pos
  posOf (CHSTokEqual   pos  ) = pos
  posOf (CHSTokStar    pos  ) = pos
  posOf (CHSTokLBrace  pos  ) = pos
  posOf (CHSTokRBrace  pos  ) = pos
  posOf (CHSTokLParen  pos  ) = pos
  posOf (CHSTokRParen  pos  ) = pos
  posOf (CHSTokEndHook pos  ) = pos
  posOf (CHSTokAs      pos  ) = pos
  posOf (CHSTokCall    pos  ) = pos
  posOf (CHSTokContext pos  ) = pos
  posOf (CHSTokDerive  pos  ) = pos
  posOf (CHSTokEnum    pos  ) = pos
  posOf (CHSTokForeign pos  ) = pos
  posOf (CHSTokFun     pos  ) = pos
  posOf (CHSTokGet     pos  ) = pos
  posOf (CHSTokHeader  pos  ) = pos
  posOf (CHSTokImport  pos  ) = pos
  posOf (CHSTokLib     pos  ) = pos
  posOf (CHSTokNewtype pos  ) = pos
  posOf (CHSTokPointer pos  ) = pos
  posOf (CHSTokPrefix  pos  ) = pos
  posOf (CHSTokQualif  pos  ) = pos
  posOf (CHSTokSet     pos  ) = pos
  posOf (CHSTokSizeof  pos  ) = pos
  posOf (CHSTokStable  pos  ) = pos
  posOf (CHSTokType    pos  ) = pos
  posOf (CHSTok_2Case  pos  ) = pos
  posOf (CHSTokUnsafe  pos  ) = pos
  posOf (CHSTokWith    pos  ) = pos
  posOf (CHSTokString  pos _) = pos
  posOf (CHSTokIdent   pos _) = pos
  posOf (CHSTokHaskell pos _) = pos
  posOf (CHSTokCtrl    pos _) = pos

instance Eq CHSToken where
  (CHSTokArrow    _  ) == (CHSTokArrow    _  ) = True
  (CHSTokDot      _  ) == (CHSTokDot      _  ) = True
  (CHSTokComma    _  ) == (CHSTokComma    _  ) = True
  (CHSTokEqual    _  ) == (CHSTokEqual    _  ) = True
  (CHSTokStar     _  ) == (CHSTokStar     _  ) = True
  (CHSTokLBrace   _  ) == (CHSTokLBrace   _  ) = True
  (CHSTokRBrace   _  ) == (CHSTokRBrace   _  ) = True
  (CHSTokLParen   _  ) == (CHSTokLParen   _  ) = True
  (CHSTokRParen   _  ) == (CHSTokRParen   _  ) = True
  (CHSTokEndHook  _  ) == (CHSTokEndHook  _  ) = True
  (CHSTokAs       _  ) == (CHSTokAs       _  ) = True
  (CHSTokCall     _  ) == (CHSTokCall     _  ) = True
  (CHSTokContext  _  ) == (CHSTokContext  _  ) = True
  (CHSTokDerive   _  ) == (CHSTokDerive   _  ) = True
  (CHSTokEnum     _  ) == (CHSTokEnum     _  ) = True
  (CHSTokForeign  _  ) == (CHSTokForeign  _  ) = True
  (CHSTokFun      _  ) == (CHSTokFun      _  ) = True
  (CHSTokGet      _  ) == (CHSTokGet      _  ) = True
  (CHSTokHeader   _  ) == (CHSTokHeader   _  ) = True
  (CHSTokImport   _  ) == (CHSTokImport   _  ) = True
  (CHSTokLib      _  ) == (CHSTokLib      _  ) = True
  (CHSTokNewtype  _  ) == (CHSTokNewtype  _  ) = True
  (CHSTokPointer  _  ) == (CHSTokPointer  _  ) = True
  (CHSTokPrefix   _  ) == (CHSTokPrefix   _  ) = True
  (CHSTokQualif   _  ) == (CHSTokQualif   _  ) = True
  (CHSTokSet      _  ) == (CHSTokSet      _  ) = True
  (CHSTokSizeof   _  ) == (CHSTokSizeof   _  ) = True
  (CHSTokStable   _  ) == (CHSTokStable   _  ) = True
  (CHSTokType     _  ) == (CHSTokType     _  ) = True
  (CHSTok_2Case   _  ) == (CHSTok_2Case   _  ) = True
  (CHSTokUnsafe   _  ) == (CHSTokUnsafe   _  ) = True
  (CHSTokWith     _  ) == (CHSTokWith     _  ) = True
  (CHSTokString   _ _) == (CHSTokString   _ _) = True
  (CHSTokIdent    _ _) == (CHSTokIdent    _ _) = True
  (CHSTokHaskell  _ _) == (CHSTokHaskell  _ _) = True
  (CHSTokCtrl	  _ _) == (CHSTokCtrl	  _ _) = True
  _		       == _		       = False

instance Show CHSToken where
  showsPrec _ (CHSTokArrow   _  ) = showString "->"
  showsPrec _ (CHSTokDot     _  ) = showString "."
  showsPrec _ (CHSTokComma   _  ) = showString ","
  showsPrec _ (CHSTokEqual   _  ) = showString "="
  showsPrec _ (CHSTokStar    _  ) = showString "*"
  showsPrec _ (CHSTokLBrace  _  ) = showString "{"
  showsPrec _ (CHSTokRBrace  _  ) = showString "}"
  showsPrec _ (CHSTokLParen  _  ) = showString "("
  showsPrec _ (CHSTokRParen  _  ) = showString ")"
  showsPrec _ (CHSTokEndHook _  ) = showString "#}"
  showsPrec _ (CHSTokAs      _  ) = showString "as"
  showsPrec _ (CHSTokCall    _  ) = showString "call"
  showsPrec _ (CHSTokContext _  ) = showString "context"
  showsPrec _ (CHSTokDerive  _  ) = showString "deriving"
  showsPrec _ (CHSTokEnum    _  ) = showString "enum"
  showsPrec _ (CHSTokForeign _  ) = showString "foreign"
  showsPrec _ (CHSTokFun     _  ) = showString "fun"
  showsPrec _ (CHSTokGet     _  ) = showString "get"
  showsPrec _ (CHSTokHeader  _  ) = showString "header"
  showsPrec _ (CHSTokImport  _  ) = showString "import"
  showsPrec _ (CHSTokLib     _  ) = showString "lib"
  showsPrec _ (CHSTokNewtype _  ) = showString "newtype"
  showsPrec _ (CHSTokPointer _  ) = showString "pointer"
  showsPrec _ (CHSTokPrefix  _  ) = showString "prefix"
  showsPrec _ (CHSTokQualif  _  ) = showString "qualified"
  showsPrec _ (CHSTokSet     _  ) = showString "set"
  showsPrec _ (CHSTokSizeof  _  ) = showString "sizeof"
  showsPrec _ (CHSTokStable  _  ) = showString "stable"
  showsPrec _ (CHSTokType    _  ) = showString "type"
  showsPrec _ (CHSTok_2Case  _  ) = showString "underscoreToCase"
  showsPrec _ (CHSTokUnsafe  _  ) = showString "unsafe"
  showsPrec _ (CHSTokWith    _  ) = showString "with"
  showsPrec _ (CHSTokString  _ s) = showString ("\"" ++ s ++ "\"")
  showsPrec _ (CHSTokIdent   _ i) = (showString . identToLexeme) i
  showsPrec _ (CHSTokHaskell _ s) = showString s
  showsPrec _ (CHSTokCtrl    _ c) = showChar c


-- lexer state
-- -----------

-- state threaded through the lexer
--
data CHSLexerState = CHSLS {
		       nestLvl :: Int,	 -- nesting depth of nested comments
		       inHook  :: Bool,	 -- within a binding hook?
		       namesup :: [Name] -- supply of unique names
		     }

-- initial state
--
initialState :: CST s CHSLexerState
initialState  = do
		  namesup <- liftM names getNameSupply
		  return $ CHSLS {
			     nestLvl = 0,
			     inHook  = False,
			     namesup = namesup
			   }

-- raise an error if the given state is not a final state
--
assertFinalState :: Position -> CHSLexerState -> CST s ()
assertFinalState pos CHSLS {nestLvl = nestLvl, inHook = inHook} 
  | nestLvl > 0 = raiseError pos ["Unexpected end of file!",
				  "Unclosed nested comment."]
  | inHook      = raiseError pos ["Unexpected end of file!",
				  "Unclosed binding hook."]
  | otherwise   = nop

-- lexer and action type used throughout this specification
--
type CHSLexer  = Lexer  CHSLexerState CHSToken
type CHSAction = Action               CHSToken
type CHSRegexp = Regexp CHSLexerState CHSToken

-- for actions that need a new unique name
--
infixl 3 `lexactionName`
lexactionName :: CHSRegexp 
	      -> (String -> Position -> Name -> CHSToken) 
	      -> CHSLexer
re `lexactionName` action = re `lexmeta` action'
  where
    action' str pos state = let name:ns = namesup state
			    in
			    (Just $ Right (action str pos name),
			     incPos pos (length str),
			     state {namesup = ns},
			     Nothing)


-- lexical specification
-- ---------------------

-- the lexical definition of the tokens (the base lexer)
--
--
chslexer :: CHSLexer
chslexer  =      haskell	-- Haskell code
	    >||< nested		-- nested comments
	    >||< ctrl		-- control code (that has to be preserved)
	    >||< hook		-- start of a binding hook

-- stream of Haskell code (terminated by a control character or binding hook)
--
haskell :: CHSLexer
haskell  = (    anyButSpecial`star` epsilon
	    >|< specialButQuotes
	    >|< char '"' +> inhstr`star` char '"'
	   )
	   `lexaction` copyVerbatim
	   >||< string "--" +> anyButNL`star` char '\n'	          -- comment
                `lexmeta` (\cs pos s -> (Just $ Right (CHSTokHaskell pos cs),
					 retPos pos, s, Nothing))
	   >||< char '"'		             -- this is a bad kludge
		`lexactionErr` 
		  \_ pos -> (Left $ makeError ErrorErr pos
					      ["Lexical error!", 
					      "Unclosed string."])
	   where
	     anyButSpecial    = alt (inlineSet \\ specialSet)
	     specialButQuotes = alt (specialSet \\ ['"'])
	     anyButNL	      = alt (anySet \\ ['\n'])
	     inhstr	      = instr >|< string "\\\"" >|< gap
	     gap	      = char '\\' +> alt (' ':ctrlSet)`star` char '\\'

-- action copying the input verbatim to `CHSTokHaskell' tokens
--
copyVerbatim        :: CHSAction 
copyVerbatim cs pos  = Just $ CHSTokHaskell pos cs

-- nested comments
--
nested :: CHSLexer
nested  =
       string "{-"		{- for Haskell emacs mode :-( -}
       `lexmeta` enterComment
  >||<
       string "-}"
       `lexmeta` leaveComment
  where
    enterComment cs pos s =
      (copyVerbatim' cs pos,			-- collect the lexeme
       incPos pos 2,				-- advance current position
       s {nestLvl = nestLvl s + 1},		-- increase nesting level
       Just $ inNestedComment)			-- continue in comment lexer
    --
    leaveComment cs pos s =
      case nestLvl s of
        0 -> (commentCloseErr pos,		-- 0: -} outside comment => err
	      incPos pos 2,			-- advance current position
	      s,
	      Nothing)
        1 -> (copyVerbatim' cs pos,		-- collect the lexeme
	      incPos pos 2,			-- advance current position
	      s {nestLvl = nestLvl s - 1},	-- decrease nesting level
	      Just chslexer)			-- 1: continue with root lexer
        _ -> (copyVerbatim' cs pos,		-- collect the lexeme
	      incPos pos 2,			-- advance current position
	      s {nestLvl = nestLvl s - 1},	-- decrease nesting level
	      Nothing)				-- _: cont with comment lexer
    --
    copyVerbatim' cs pos  = Just $ Right (CHSTokHaskell pos cs)
    --
    commentCloseErr pos =
      Just $ Left (makeError ErrorErr pos
			     ["Lexical error!", 
			     "`-}' not preceded by a matching `{-'."])
			     {- for Haskell emacs mode :-( -}


-- lexer processing the inner of a comment
--
inNestedComment :: CHSLexer
inNestedComment  =      commentInterior		-- inside a comment
		   >||< nested			-- nested comments
		   >||< ctrl			-- control code (preserved)

-- standard characters in a nested comment
--
commentInterior :: CHSLexer
commentInterior  = (    anyButSpecial`star` epsilon
		    >|< special
		   )
		   `lexaction` copyVerbatim
		   where
		     anyButSpecial = alt (inlineSet \\ commentSpecialSet)
		     special	   = alt commentSpecialSet

-- control code in the base lexer (is turned into a token)
--
-- * this covers exactly the same set of characters as contained in `ctrlSet'
--   and `Lexers.ctrlLexer' and advances positions also like the `ctrlLexer'
--
ctrl :: CHSLexer
ctrl  =     
       char '\n' `lexmeta` newline
  >||< char '\r' `lexmeta` newline
  >||< char '\v' `lexmeta` newline
  >||< char '\f' `lexmeta` formfeed
  >||< char '\t' `lexmeta` tab
  where
    newline  [c] pos = ctrlResult pos c (retPos pos)
    formfeed [c] pos = ctrlResult pos c (incPos pos 1)
    tab      [c] pos = ctrlResult pos c (tabPos pos)

    ctrlResult pos c pos' s = 
      (Just $ Right (CHSTokCtrl pos c), pos', s, Nothing)

-- start of a binding hook (ie, enter the binding hook lexer)
--
hook :: CHSLexer
hook  = string "{#"
	`lexmeta` \_ pos s -> (Nothing, incPos pos 2, s, Just bhLexer)

-- the binding hook lexer
--
bhLexer :: CHSLexer
bhLexer  =      identOrKW
	   >||< symbol
	   >||< strlit
	   >||< whitespace
	   >||< endOfHook
	   >||< string "--" +> anyButNL`star` char '\n'	  -- comment
		`lexmeta` \_ pos s -> (Nothing, retPos pos, s, Nothing)
	   where
	     anyButNL  = alt (anySet \\ ['\n'])
	     endOfHook = string "#}"
			 `lexmeta` 
			  \_ pos s -> (Just $ Right (CHSTokEndHook pos), 
				       incPos pos 2, s, Just chslexer)

-- whitespace
--
-- * horizontal and vertical tabs, newlines, and form feeds are filter out by
--   `Lexers.ctrlLexer' 
--
whitespace :: CHSLexer
whitespace  =      (char ' ' `lexaction` \_ _ -> Nothing)
	      >||< ctrlLexer

-- identifiers and keywords
--
identOrKW :: CHSLexer
--
-- the strictness annotations seem to help a bit
--
identOrKW  = 
  letter +> (letter >|< digit >|< char '\'')`star` epsilon
  `lexactionName` \cs pos name -> (idkwtok $!pos) cs name
  where
    idkwtok pos "as"               _    = CHSTokAs      pos
    idkwtok pos "call"             _    = CHSTokCall    pos
    idkwtok pos "context"          _    = CHSTokContext pos
    idkwtok pos "deriving"	   _	= CHSTokDerive  pos
    idkwtok pos "enum"             _    = CHSTokEnum    pos
    idkwtok pos "foreign"	   _	= CHSTokForeign pos
    idkwtok pos "fun"              _    = CHSTokFun     pos
    idkwtok pos "get"              _    = CHSTokGet     pos
    idkwtok pos "header"           _    = CHSTokHeader  pos
    idkwtok pos "import"           _    = CHSTokImport  pos
    idkwtok pos "lib"              _    = CHSTokLib     pos
    idkwtok pos "newtype"          _    = CHSTokNewtype pos
    idkwtok pos "pointer"          _    = CHSTokPointer pos
    idkwtok pos "prefix"           _    = CHSTokPrefix  pos
    idkwtok pos "qualified"        _    = CHSTokQualif  pos
    idkwtok pos "set"              _    = CHSTokSet     pos
    idkwtok pos "sizeof"           _    = CHSTokSizeof  pos
    idkwtok pos "stable"	   _	= CHSTokStable	pos
    idkwtok pos "type"             _    = CHSTokType    pos
    idkwtok pos "underscoreToCase" _    = CHSTok_2Case  pos
    idkwtok pos "unsafe"           _    = CHSTokUnsafe  pos
    idkwtok pos "with"             _    = CHSTokWith    pos
    idkwtok pos cs                 name = CHSTokIdent   
					    pos (lexemeToIdent pos cs name)

-- reserved symbols
--
symbol :: CHSLexer
symbol  =      sym "->" CHSTokArrow
	  >||< sym "."  CHSTokDot
	  >||< sym ","  CHSTokComma
	  >||< sym "="  CHSTokEqual
	  >||< sym "*"  CHSTokStar
	  >||< sym "{"  CHSTokLBrace
	  >||< sym "}"  CHSTokRBrace
	  >||< sym "("  CHSTokLParen
	  >||< sym ")"  CHSTokRParen
	  where
	    sym cs con = string cs `lexaction` \_ pos -> Just (con pos)

-- string
--
strlit :: CHSLexer
strlit  = char '"' +> instr`star` char '"'
	  `lexaction` \cs pos -> Just (CHSTokString pos (init . tail $ cs))


-- regular expressions
--
letter, digit, instr :: Regexp s t
letter = alt ['a'..'z'] >|< alt ['A'..'Z'] >|< char '_'
digit  = alt ['0'..'9']
instr  = alt ([' '..'\127'] \\ ['\"'])

-- character sets
--
anySet, inlineSet, specialSet, commentSpecialSet, ctrlSet :: [Char]
anySet            = ['\0'..'\255']
inlineSet         = anySet \\ ctrlSet
specialSet        = ['{', '-', '"']
commentSpecialSet = ['{', '-']
ctrlSet           = ['\n', '\f', '\r', '\t', '\v']


-- main lexing routine
-- -------------------

-- generate a token sequence out of a string denoting a CHS file
-- (EXPORTED) 
--
-- * the given position is attributed to the first character in the string
--
-- * errors are entered into the compiler state
--
lexCHS        :: String -> Position -> CST s [CHSToken]
lexCHS cs pos  = 
  do
    state <- initialState
    let (ts, lstate, errs) = execLexer chslexer (cs, pos, state)
        (_, pos', state')  = lstate
    mapM raise errs
    assertFinalState pos' state'
    return ts
