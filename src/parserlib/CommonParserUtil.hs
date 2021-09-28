{-# LANGUAGE GADTs #-}
module CommonParserUtil
  ( LexerSpec(..), ParserSpec(..)
  , lexing, lexingWithLineColumn, parsing, runAutomaton, parsingHaskell, runAutomatonHaskell
  , get, getText
  , LexError(..), ParseError(..)
  , successfullyParsed, handleLexError, handleParseError) where

import Terminal
import TokenInterface

import Text.Regex.TDFA
import System.Exit
import System.Process
import Control.Monad

import Data.Typeable
import Control.Exception

import SaveProdRules
import AutomatonType
import LoadAutomaton

import Data.List (nub)
import Data.Maybe

import SynCompInterface

import Prelude hiding (catch)
import System.Directory
import Control.Exception
import System.IO.Error hiding (catch)

-- Lexer Specification
type RegExpStr    = String
type LexFun token = String -> Maybe token 

type LexerSpecList token  = [(RegExpStr, LexFun token)]
data LexerSpec token =
  LexerSpec { endOfToken    :: token,
              lexerSpecList :: LexerSpecList token
            }

-- Parser Specification
type ProdRuleStr = String
type ParseFun token ast = Stack token ast -> ast

type ParserSpecList token ast = [(ProdRuleStr, ParseFun token ast)]
data ParserSpec token ast =
  ParserSpec { startSymbol    :: String,
               parserSpecList :: ParserSpecList token ast,
               baseDir        :: String,   -- ex) ./
               actionTblFile  :: String,   -- ex) actiontable.txt
               gotoTblFile    :: String,   -- ex) gototable.txt
               grammarFile    :: String,   -- ex) grammar.txt
               parserSpecFile :: String,   -- ex) mygrammar.grm
               genparserexe   :: String    -- ex) genlrparse-exe
             }

-- Specification
data Spec token ast =
  Spec (LexerSpec token) (ParserSpec token ast)

--------------------------------------------------------------------------------  
-- The lexing machine
--------------------------------------------------------------------------------  
type Line = Int
type Column = Int

--
data LexError = LexError Int Int String  -- Line, Col, Text
  deriving (Typeable, Show)

instance Exception LexError

-- prLexError (CommonParserUtil.LexError line col text) = do
--   putStr $ "No matching lexer spec at "
--   putStr $ "Line " ++ show line
--   putStr $ "Column " ++ show col
--   putStr $ " : "
--   putStr $ take 10 text

--
lexing :: TokenInterface token =>
          LexerSpec token -> String -> IO [Terminal token]
lexing lexerspec text = do
  (line, col, terminalList) <- lexingWithLineColumn lexerspec 1 1 text
  return terminalList

lexingWithLineColumn :: TokenInterface token =>
           LexerSpec token -> Line -> Column -> String -> IO (Line, Column, [Terminal token])
lexingWithLineColumn lexerspec line col [] = do
  let eot = endOfToken lexerspec 
  return (line, col, [Terminal (fromToken eot) line col (Just eot)])
   
lexingWithLineColumn lexerspec line col text = do  --Todo: make it tail-recursive!
  (matchedText, theRestText, maybeTok) <-
    matchLexSpec line col (lexerSpecList lexerspec) text
  let (line_, col_) = moveLineCol line col matchedText
  (line__, col__, terminalList) <- lexingWithLineColumn lexerspec line_ col_ theRestText
  case maybeTok of
    Nothing  -> return (line__, col__, terminalList)
    Just tok -> do
      let terminal = Terminal matchedText line col (Just tok)
      return (line__, col__, terminal:terminalList)

matchLexSpec :: TokenInterface token =>
                Line -> Column -> LexerSpecList token -> String
             -> IO (String, String, Maybe token)
matchLexSpec line col [] text = do
  throw (CommonParserUtil.LexError line col text)
  -- putStr $ "No matching lexer spec at "
  -- putStr $ "Line " ++ show line
  -- putStr $ "Column " ++ show col
  -- putStr $ " : "
  -- putStr $ take 10 text
  -- exitWith (ExitFailure (-1))

matchLexSpec line col ((aSpec,tokenBuilder):lexerspec) text = do
  let (pre, matched, post) = text =~ aSpec :: (String,String,String)
  case pre of
    "" -> return (matched, post, tokenBuilder matched)
    _  -> matchLexSpec line col lexerspec text


moveLineCol :: Line -> Column -> String -> (Line, Column)
moveLineCol line col ""          = (line, col)
moveLineCol line col ('\n':text) = moveLineCol (line+1) 1 text
moveLineCol line col (ch:text)   = moveLineCol line (col+1) text
  
--------------------------------------------------------------------------------  
-- The parsing machine
--------------------------------------------------------------------------------

type CurrentState    = Int
type StateOnStackTop = Int
type LhsSymbol = String

type AutomatonSnapshot token ast =   -- TODO: Refactoring
  (Stack token ast, ActionTable, GotoTable, ProdRules)

--
data ParseError token ast where
    -- teminal, state, stack actiontbl, gototbl
    NotFoundAction :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
      (Terminal token) -> CurrentState -> (Stack token ast) -> ActionTable -> GotoTable -> ProdRules -> [Terminal token] -> ParseError token ast
    
    -- topState, lhs, stack, actiontbl, gototbl,
    NotFoundGoto :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
       StateOnStackTop -> LhsSymbol -> (Stack token ast) -> ActionTable -> GotoTable -> ProdRules -> [Terminal token] -> ParseError token ast

  deriving (Typeable)

instance (Show token, Show ast) => Show (ParseError token ast) where
  showsPrec p (NotFoundAction terminal state stack _ _ _ _) =
    (++) "NotFoundAction: " . (++) (show state) . (++) " " . (++) (terminalToString terminal) -- (++) (show $ length stack)
  showsPrec p (NotFoundGoto topstate lhs stack _ _ _ _) =
    (++) "NotFoundGoto: " . (++) (show topstate) . (++) " " . (++) lhs -- . (++) (show stack)

instance (TokenInterface token, Typeable token, Show token, Typeable ast, Show ast)
  => Exception (ParseError token ast)

-- prParseError (NotFoundAction terminal state stack actiontbl gototbl prodRules terminalList) = do
--   putStrLn $
--     ("Not found in the action table: "
--      ++ terminalToString terminal)
--      ++ " : "
--      ++ show (state, tokenTextFromTerminal terminal)
--      ++ " (" ++ show (length terminalList) ++ ")"
--      ++ "\n" ++ prStack stack ++ "\n"
     
-- prParseError (NotFoundGoto topState lhs stack actiontbl gototbl prodRules terminalList) = do
--   putStrLn $
--     ("Not found in the goto table: ")
--      ++ " : "
--      ++ show (topState,lhs) ++ "\n"
--      ++ " (" ++ show (length terminalList) ++ ")"
--      ++ prStack stack ++ "\n"

--
parsing flag parserSpec terminalList =
  parsingHaskell flag parserSpec terminalList Nothing
  
parsingHaskell :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
           Bool -> ParserSpec token ast -> [Terminal token] -> Maybe token -> IO ast
parsingHaskell flag parserSpec terminalList haskellOption = do
  -- 1. Save the production rules in the parser spec (Parser.hs).
  writtenBool <- saveProdRules specFileName sSym pSpecList

  -- 2. If the grammar file is written,
  --    run the following command to generate prod_rules/action_table/goto_table files.
  --     stack exec -- yapb-exe mygrammar.grm -output prod_rules.txt action_table.txt goto_table.txt
  when writtenBool generateAutomaton

  -- 3. Load automaton files (prod_rules/action_table/goto_table.txt)
  (actionTbl, gotoTbl, prodRules) <-
    loadAutomaton grammarFileName actionTblFileName gotoTblFileName

  -- 4. Run the automaton
  if null actionTbl || null gotoTbl || null prodRules
    then do let hashFile = getHashFileName specFileName
            putStrLn $ "Delete " ++ hashFile
            removeIfExists hashFile
            error $ "Error: Empty automation: please rerun"
    else do ast <- runAutomatonHaskell flag initState actionTbl gotoTbl prodRules pFunList terminalList haskellOption
            -- putStrLn "done." -- It was for the interafce with Java-version RPC calculus interpreter.
            return ast

  where
    specFileName      = parserSpecFile parserSpec
    grammarFileName   = grammarFile    parserSpec
    actionTblFileName = actionTblFile  parserSpec
    gotoTblFileName   = gotoTblFile    parserSpec
    
    sSym      = startSymbol parserSpec
    pSpecList = map fst (parserSpecList parserSpec)
    pFunList  = map snd (parserSpecList parserSpec)

    generateAutomaton = do
      exitCode <- rawSystem "stack"
                  [ "exec", "--",
                    "yapb-exe", specFileName, "-output",
                    grammarFileName, actionTblFileName, gotoTblFileName
                  ]
      case exitCode of
        ExitFailure code -> exitWith exitCode
        ExitSuccess -> putStrLn ("Successfully generated: " ++
                                 actionTblFileName ++ ", "  ++
                                 gotoTblFileName ++ ", " ++
                                 grammarFileName);
--
removeIfExists :: FilePath -> IO ()
removeIfExists fileName = removeFile fileName `catch` handleExists
  where handleExists e
          | isDoesNotExistError e = return ()
          | otherwise = throwIO e

-- Stack

data StkElem token ast =
    StkState Int
  | StkTerminal (Terminal token)
  | StkNonterminal (Maybe ast) String -- String for printing Nonterminal instead of ast

instance TokenInterface token => Eq (StkElem token ast) where
  (StkState i)          == (StkState j)          = i == j
  (StkTerminal termi)   == (StkTerminal termj)   = tokenTextFromTerminal termi == tokenTextFromTerminal termj
  (StkNonterminal _ si) == (StkNonterminal _ sj) = si == sj

type Stack token ast = [StkElem token ast]

emptyStack = []

get :: Stack token ast -> Int -> ast
get stack i =
  case stack !! (i-1) of
    StkNonterminal (Just ast) _ -> ast
    StkNonterminal Nothing _ -> error $ "get: empty ast in the nonterminal at stack"
    _ -> error $ "get: out of bound: " ++ show i

getText :: Stack token ast -> Int -> String
getText stack i = 
  case stack !! (i-1) of
    StkTerminal (Terminal text _ _ _) -> text
    _ -> error $ "getText: out of bound: " ++ show i

push :: a -> [a] -> [a]
push elem stack = elem:stack

pop :: [a] -> (a, [a])
pop (elem:stack) = (elem, stack)
pop []           = error "Attempt to pop from the empty stack"

prStack :: TokenInterface token => Stack token ast -> String
prStack [] = "STACK END"
prStack (StkState i : stack) = "S" ++ show i ++ " : " ++ prStack stack
prStack (StkTerminal (Terminal text _ _ (Just token)) : stack) =
  let str_token = fromToken token in
  (if str_token == text then str_token else (fromToken token ++ " i.e. " ++ text))
    ++  " : " ++ prStack stack
prStack (StkTerminal (Terminal text _ _ Nothing) : stack) =
  (token_na ++ " " ++ text) ++  " : " ++ prStack stack
prStack (StkNonterminal _ str : stack) = str ++ " : " ++ prStack stack

-- Utility for Automation
currentState :: Stack token ast -> Int
currentState (StkState i : stack) = i
currentState _                    = error "No state found in the stack top"

tokenTextFromTerminal :: TokenInterface token => Terminal token -> String
tokenTextFromTerminal (Terminal _ _ _ (Just token)) = fromToken token
tokenTextFromTerminal (Terminal _ _ _ Nothing) = token_na

lookupActionTable :: TokenInterface token => ActionTable -> Int -> (Terminal token) -> Maybe Action
lookupActionTable actionTbl state terminal =
  lookupTable actionTbl (state,tokenTextFromTerminal terminal)
     ("Not found in the action table: " ++ terminalToString terminal) 

lookupGotoTable :: GotoTable -> Int -> String -> Maybe Int
lookupGotoTable gotoTbl state nonterminalStr =
  lookupTable gotoTbl (state,nonterminalStr)
     ("Not found in the goto table: ")

lookupTable :: (Eq a, Show a) => [(a,b)] -> a -> String -> Maybe b
lookupTable tbl key msg =   
  case [ val | (key', val) <- tbl, key==key' ] of
    [] -> Nothing -- error $ msg ++ " : " ++ show key
    (h:_) -> Just h


-- Note: take 1th, 3rd, 5th, ... of 2*len elements from stack and reverse it!
-- example) revTakeRhs 2 [a1,a2,a3,a4,a5,a6,...]
--          = [a4, a2]
revTakeRhs :: Int -> [a] -> [a]
revTakeRhs 0 stack = []
revTakeRhs n (_:nt:stack) = revTakeRhs (n-1) stack ++ [nt]

-- Automaton

initState = 0

type ParseFunList token ast = [ParseFun token ast]

runAutomaton flag initState actionTbl gotoTbl prodRules pFunList terminalList =
  runAutomatonHaskell flag initState actionTbl gotoTbl prodRules pFunList terminalList Nothing

runAutomatonHaskell :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
  Bool -> Int -> 
  {- static part -}
  ActionTable -> GotoTable -> ProdRules -> ParseFunList token ast -> 
  {- dynamic part -}
  [Terminal token] ->
  {- haskell parser specific option -}
  Maybe token ->
  {- AST -}
  IO ast
runAutomatonHaskell flag initState actionTbl gotoTbl prodRules pFunList terminalList haskellOption = do
  let initStack = push (StkState initState) emptyStack
  run terminalList initStack
  
  where
    {- run :: TokenInterface token => [Terminal token] -> Stack token ast -> IO ast -}
    run terminalList stack = do
      let state = currentState stack
      let terminal = head terminalList
      case lookupActionTable actionTbl state terminal of
        Just action -> do
          -- putStrLn $ terminalToString terminal {- debug -}
          runAction state terminal action terminalList stack
          
        Nothing -> do
          putStrLn $ "lookActionTable failed (1st) with: " ++ show (terminalToString terminal)
          case haskellOption of
            Just extraToken -> do
              let terminal_close_brace = Terminal
                                          (fromToken extraToken)
                                            (terminalToLine terminal)
                                              (terminalToCol terminal)
                                                (Just extraToken)
              case lookupActionTable actionTbl state terminal_close_brace of
                Just action -> do
                  -- putStrLn $ terminalToString terminal_close_brace {- debug -}
                  putStrLn $ "lookActionTable succeeded (2nd) with: " ++ terminalToString terminal_close_brace
                  runAction state terminal_close_brace action (terminal_close_brace : terminalList) stack
                  
                Nothing -> do
                  putStrLn $ "lookActionTable failed (2nd) with: " ++ terminalToString terminal_close_brace
                  throw (NotFoundAction terminal state stack actionTbl gotoTbl prodRules terminalList)
                -- Nothing -> throw (NotFoundAction terminal_close_brace state stack actionTbl gotoTbl prodRules
                --                    (terminal_close_brace : terminalList))
                           
            Nothing -> throw (NotFoundAction terminal state stack actionTbl gotoTbl prodRules terminalList)

    -- separated to support the haskell layout rule
    runAction state terminal action terminalList stack = do      
      debug flag ("\nState " ++ show state)
      debug flag ("Token " ++ tokenTextFromTerminal terminal)
      debug flag ("Stack " ++ prStack stack)
      
      case action of
        Accept -> do
          debug flag "Accept"
          putStrLn $ terminalToString terminal {- debug -}
          
          case stack !! 1 of
            StkNonterminal (Just ast) _ -> return ast
            StkNonterminal Nothing _ -> fail "Empty ast in the stack nonterminal"
            _ -> fail "Not Stknontermianl on Accept"
        
        Shift toState -> do
          debug flag ("Shift " ++ show toState)
          putStrLn $ terminalToString terminal {- debug -}
          
          let stack1 = push (StkTerminal (head terminalList)) stack
          let stack2 = push (StkState toState) stack1
          run (tail terminalList) stack2
          
        Reduce n -> do
          debug flag ("Reduce " ++ show n)
          
          let prodrule   = prodRules !! n
          
          debug flag ("\t" ++ show prodrule)
          
          let builderFun = pFunList  !! n
          let lhs        = fst prodrule
          let rhsLength  = length (snd prodrule)
          let rhsAst = revTakeRhs rhsLength stack
          let ast = builderFun rhsAst
          let stack1 = drop (rhsLength*2) stack
          let topState = currentState stack1
          let toState =
               case lookupGotoTable gotoTbl topState lhs of
                 Just state -> state
                 Nothing -> throw (NotFoundGoto topState lhs stack actionTbl gotoTbl prodRules terminalList)
  
          let stack2 = push (StkNonterminal (Just ast) lhs) stack1
          let stack3 = push (StkState toState) stack2
          run terminalList stack3

debug :: Bool -> String -> IO ()
debug flag msg = if flag then putStrLn msg else return ()

prlevel n = take n (let spaces = ' ' : spaces in spaces)

-- | Computing candidates

data Candidate =     -- Todo: data Candidate vs. data EmacsDataItem = ... | Candidate String 
    TerminalSymbol String
  | NonterminalSymbol String
  deriving (Show,Eq)

data Automaton token ast =
  Automaton {
    actTbl    :: ActionTable,
    gotoTbl   :: GotoTable,
    prodRules :: ProdRules
  }
  
compCandidates
  :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
     Bool      -- debug
     -> Int    -- maximum search depth level
     -> Bool   -- simple or nested
     -> Int
     -> [Candidate]
     -> Int
     -> Automaton token ast
     -> Stack token ast
     -> IO [[Candidate]]

compCandidates flag maxLevel isSimple level symbols state automaton stk = do
  compGammasDfs flag maxLevel isSimple level symbols state automaton stk []
--  gammas <- compGammasDfs isSimple level symbols state automaton stk []
--  if isSimple
--  then return gammas
--  else return $ tail $ scanl (++) [] (filter (not . null) gammas)

compGammasDfs
  :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast) =>
     Bool
     -> Int
     -> Bool
     -> Int
     -> [Candidate]
     -> Int
     -> Automaton token ast
     -> Stack token ast
     -> [(Int, Stack token ast, String)]
     -> IO [[Candidate]]

compGammasDfs flag maxLevel isSimple level symbols state automaton stk history =
  if level > maxLevel then
    return (if null symbols then [] else [symbols])
  else
  checkCycle flag False level state stk "" history
   (\history -> 
     case nub [prnum | ((s,lookahead),Reduce prnum) <- actTbl automaton, state==s] of
      [] ->
        case nub [(nonterminal,toState) | ((fromState,nonterminal),toState) <- gotoTbl automaton, state==fromState] of
          [] ->
            if length [True | ((s,lookahead),Accept) <- actTbl automaton, state==s] >= 1
            then do 
                   return []
            else let cand2 = nub [(terminal,snext) | ((s,terminal),Shift snext) <- actTbl automaton, state==s] in
                 let len = length cand2 in
                 case cand2 of
                  [] -> return []
               
                  _  -> do listOfList <-
                             mapM (\ ((terminal,snext),i)->
                                let stk1 = push (StkTerminal (Terminal terminal 0 0 Nothing)) stk  -- Todo: ??? (toToken terminal)
                                    stk2 = push (StkState snext) stk1
                                in 
                                -- checkCycle False level snext stk2 ("SHIFT " ++ show snext ++ " " ++ terminal) history
                                -- checkCycle True level state stk terminal history
                                checkCycle flag True level snext stk2 terminal history
                             
                                  (\history1 -> do
                                   debug flag $ prlevel level ++ "SHIFT [" ++ show i ++ "/" ++ show len ++ "]: "
                                             ++ show state ++ " -> " ++ terminal ++ " -> " ++ show snext
                                   debug flag $ prlevel level ++ "Goto/Shift symbols: " ++ show (symbols++[TerminalSymbol terminal])
                                   debug flag $ prlevel level ++ "Stack " ++ prStack stk2
                                   debug flag $ ""
                                   compGammasDfs flag maxLevel isSimple (level+1) (symbols++[TerminalSymbol terminal]) snext automaton stk2 history1) )
                                     (zip cand2 [1..])
                           return $ concat listOfList
          nontermStateList -> do
            let len = length nontermStateList
   
            listOfList <-
              mapM (\ ((nonterminal,snext),i) ->
                 let stk1 = push (StkNonterminal Nothing nonterminal) stk
                     stk2 = push (StkState snext) stk1
                 in 
                 -- checkCycle False level snext stk2 ("GOTO " ++ show snext ++ " " ++ nonterminal) history
                 -- checkCycle True level state stk nonterminal history
                 checkCycle flag True level snext stk2 nonterminal history
              
                   (\history1 -> do
                    debug flag $ prlevel level ++ "GOTO [" ++ show i ++ "/" ++ show len ++ "] at "
                             ++ show state ++ " -> " ++ show nonterminal ++ " -> " ++ show snext
                    debug flag $ prlevel level ++ "Goto/Shift symbols:" ++ show (symbols++[NonterminalSymbol nonterminal])
                    debug flag $ prlevel level ++ "Stack " ++ prStack stk2
                    debug flag $ ""
      
                    compGammasDfs flag maxLevel isSimple (level+1) (symbols++[NonterminalSymbol nonterminal]) snext automaton stk2 history1) )
                      (zip nontermStateList [1..])
            return $ concat listOfList

      prnumList -> do
        let len = length prnumList
     
        debug flag $ prlevel level     ++ "# of prNumList to reduce: " ++ show len ++ " at State " ++ show state
        debug flag $ prlevel (level+1) ++ show [ (prodRules automaton) !! prnum | prnum <- prnumList ]
     
        -- let aCandidate = if null symbols then [] else [symbols]
        -- if isSimple
        -- then return aCandidate
        -- else do listOfList <-
        do listOfList <-
            mapM (\ (prnum,i) -> (
              -- checkCycle False level state stk ("REDUCE " ++ show prnum) history
              checkCycle flag True level state stk (show prnum) history
                (\history1 -> do
                   debug flag $ prlevel level ++ "State " ++ show state  ++ "[" ++ show i ++ "/" ++ show len ++ "]" 
                   debug flag $ prlevel level ++ "REDUCE" ++ " prod #" ++ show prnum
                   debug flag $ prlevel level ++ show ((prodRules automaton) !! prnum)
                   debug flag $ prlevel level ++ "Goto/Shift symbols: " ++ show symbols
                   debug flag $ prlevel level ++ "Stack " ++ prStack stk
                   debug flag $ ""
                   compGammasDfsForReduce flag maxLevel level isSimple  symbols state automaton stk history1 prnum)) )
                 (zip prnumList [1..])
           return $ concat listOfList )
  
compGammasDfsForReduce flag maxLevel level isSimple  symbols state automaton stk history prnum = 
  let prodrule   = (prodRules automaton) !! prnum
      lhs = fst prodrule
      rhs = snd prodrule
      
      rhsLength = length rhs
  in 
  if ( {- rhsLength == 0 || -} (rhsLength > length symbols) ) == False
  then do
    debug flag $ prlevel level ++ "[LEN COND: False] length rhs > length symbols: NOT " ++ show rhsLength ++ ">" ++ show (length symbols)
    debug flag $ prlevel (level+1) ++ show symbols
    debug flag $ prlevel level
    return [] -- Todo: (if null symbols then [] else [symbols])
  else do
    let stk1 = drop (rhsLength*2) stk
    let topState = currentState stk1
    let toState =
         case lookupGotoTable (gotoTbl automaton) topState lhs of
           Just state -> state
           Nothing -> error $ "[compGammasDfsForReduce] Must not happen: lhs: " ++ lhs ++ " state: " ++ show topState
    let stk2 = push (StkNonterminal Nothing lhs) stk1  -- ast
    let stk3 = push (StkState toState) stk2
    debug flag $ prlevel level ++ "GOTO after REDUCE: " ++ show topState ++ " " ++ lhs ++ " " ++ show toState
    debug flag $ prlevel level ++ "Goto/Shift symbols: " ++ "[]"
    debug flag $ prlevel level ++ "Stack " ++ prStack stk3
    debug flag $ ""

    debug flag $ prlevel level ++ "Found a gamma: " ++ show symbols
    debug flag $ ""

    if isSimple
    then return (if null symbols then [] else [symbols])
    else do listOfList <- compGammasDfs flag maxLevel isSimple (level+1) [] toState automaton stk3 history
            return (if null symbols then listOfList else (symbols : map (symbols ++) listOfList))

-- | Cycle checking
noCycleCheck :: Bool
noCycleCheck = True

checkCycle debugflag flag level state stk action history cont =
  if flag && (state,stk,action) `elem` history
  then do
    debug debugflag $ prlevel level ++ "CYCLE is detected !!"
    debug debugflag $ prlevel level ++ show state ++ " " ++ action
    debug debugflag $ prlevel level ++ prStack stk
    debug debugflag $ ""
    return []
  else cont ( (state,stk,action) : history )

-- | Parsing programming interfaces

-- | successfullyParsed
successfullyParsed :: IO [EmacsDataItem]
successfullyParsed = return [SynCompInterface.SuccessfullyParsed]

-- | handleLexError
handleLexError :: IO [EmacsDataItem]
handleLexError = return [SynCompInterface.LexError]

-- | handleParseError
handleParseError :: TokenInterface token => Bool -> Int -> Bool -> [Terminal token] -> ParseError token ast -> IO [EmacsDataItem]
handleParseError flag maxLevel isSimple terminalListAfterCursor parseError =
  unwrapParseError flag maxLevel isSimple terminalListAfterCursor parseError
  
unwrapParseError flag maxLevel isSimple terminalListAfterCursor (NotFoundAction _ state stk actTbl gotoTbl prodRules terminalList) =
  arrivedAtTheEndOfSymbol flag maxLevel isSimple terminalListAfterCursor state stk actTbl gotoTbl prodRules terminalList
unwrapParseError flag maxLevel isSimple terminalListAfterCursor (NotFoundGoto state _ stk actTbl gotoTbl prodRules terminalList) =
  arrivedAtTheEndOfSymbol flag maxLevel isSimple terminalListAfterCursor state stk actTbl gotoTbl prodRules terminalList

arrivedAtTheEndOfSymbol flag maxLevel isSimple terminalListAfterCursor state stk _actTbl _gotoTbl _prodRules terminalList =
  if length terminalList == 1 then do -- [$]
     _handleParseError flag maxLevel isSimple terminalListAfterCursor state stk _actTbl _gotoTbl _prodRules
  else do
     putStrLn $ "length terminalList /= 1 : " ++ show (length terminalList)
     mapM_ (\t -> putStrLn $ terminalToString $ t) terminalList
     return [SynCompInterface.ParseError (map terminalToString terminalList)]

_handleParseError flag maxLevel isSimple terminalListAfterCursor state stk _actTbl _gotoTbl _prodRules = do
  let automaton = Automaton {actTbl=_actTbl, gotoTbl=_gotoTbl, prodRules=_prodRules}
  candidateListList <- compCandidates flag maxLevel isSimple 0 [] state automaton stk
  let colorListList =
       [ filterCandidates candidateList terminalListAfterCursor | candidateList <- candidateListList ]
  let strList = nub [ concatStrList strList | strList <- map (map showEmacsColor) colorListList ]
  let rawStrListList = nub [ strList | strList <- map (map showRawEmacsColor) colorListList ]
  debug flag $ show $ map (\x -> (show x ++ "\n")) rawStrListList -- mapM_ (putStrLn . show) rawStrListList
  return $ map Candidate strList

-- | Filter the given candidates with the following texts
data EmacsColor =
    Gray  String Line Column -- Overlapping with some in the following text
  | White String             -- Not overlapping
  deriving Show

filterCandidates :: (TokenInterface token) => [Candidate] -> [Terminal token] -> [EmacsColor]
filterCandidates candidates terminalListAfterCursor =
  f candidates terminalListAfterCursor []
  where
    f (a:alpha) (b:beta) accm
      | equal a b       = f alpha beta     (Gray (strCandidate a) (terminalToLine b) (terminalToCol b) : accm)
      | otherwise       = f alpha (b:beta) (White (strCandidate a) : accm)
    f [] beta accm      = reverse accm
    f (a:alpha) [] accm = f alpha [] (White (strCandidate a) : accm)

    equal (TerminalSymbol s1)    (Terminal s2 _ _ _) = s1==s2
    equal (NonterminalSymbol s1) _                   = False

    strCandidate (TerminalSymbol s) = s
    strCandidate (NonterminalSymbol s) = "..." -- ++ s ++ "..."

-- | Utilities
showSymbol (TerminalSymbol s) = s
showSymbol (NonterminalSymbol _) = "..."

showRawSymbol (TerminalSymbol s) = s
showRawSymbol (NonterminalSymbol s) = s

showEmacsColor (Gray s line col) = "gray " ++ s ++ " " ++ show line ++ " " ++ show col ++ " "
showEmacsColor (White s)         = "white " ++ s

showRawEmacsColor (Gray s line col) = s ++ "@" ++ show line ++ "," ++ show col ++ " "
showRawEmacsColor (White s)         = s

concatStrList [] = "" -- error "The empty candidate?"
concatStrList [str] = str
concatStrList (str:strs) = str ++ " " ++ concatStrList strs

-- Q. Can we make it be typed???
--
-- computeCandWith :: (TokenInterface token, Typeable token, Typeable ast, Show token, Show ast)
--     => LexerSpec token -> ParserSpec token ast
--     -> String -> Bool -> Int -> IO [EmacsDataItem]
-- computeCandWith lexerSpec parserSpec str isSimple cursorPos = ((do
--   terminalList <- lexing lexerSpec str 
--   ast <- parsing parserSpec terminalList 
--   successfullyParsed)
--   `catch` \e -> case e :: LexError of _ -> handleLexError
--   `catch` \e -> case e :: ParseError token ast of _ -> handleParseError isSimple e)    
