{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | A nonoptimising interpreter for L0.  It makes no assumptions of
-- the form of the input program, and in particular permits shadowing.
-- This interpreter should be considered the primary benchmark for
-- judging the correctness of a program, but note that it is not by
-- itself sufficient.  The interpreter does not perform in-place
-- updates like the native code generator, and bugs related to
-- uniqueness will therefore not be detected.  Of course, the type
-- checker should catch such error.
--
-- To run an L0 program, you would normally run the interpreter as
-- @'runFun' 'defaultEntryPoint' args prog@.
module L0C.Interpreter
  ( runFun
  , runFunNoTrace
  , Trace
  , InterpreterError(..) )
where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Error

import Data.Array
import Data.Bits
import Data.List
import Data.Loc
import qualified Data.HashMap.Strict as HM

import L0C.InternalRep

-- | An error happened during execution, and this is why.
data InterpreterError = MissingEntryPoint Name
                      -- ^ The specified start function does not exist.
                      | InvalidFunctionArguments Name (Maybe [DeclType]) [DeclType]
                      -- ^ The arguments given to a function were mistyped.
                      | IndexOutOfBounds SrcLoc Int Int
                      -- ^ First @Int@ is array size, second is attempted index.
                      | NegativeIota SrcLoc Int
                      -- ^ Called @iota(n)@ where @n@ was negative.
                      | NegativeReplicate SrcLoc Int
                      -- ^ Called @replicate(n, x)@ where @n@ was negative.
                      | InvalidArrayShape SrcLoc [Int] [Int]
                      -- ^ First @Int@ is old shape, second is attempted new shape.
                      | ZipError SrcLoc [Int]
                      -- ^ The arguments to @zip@ were of different lengths.
                      | AssertFailed SrcLoc
                      -- ^ Assertion failed at this location.
                      | TypeError SrcLoc String
                      -- ^ Some value was of an unexpected type.

instance Show InterpreterError where
  show (MissingEntryPoint fname) =
    "Program entry point '" ++ nameToString fname ++ "' not defined."
  show (InvalidFunctionArguments fname Nothing got) =
    "Function '" ++ nameToString fname ++ "' did not expect argument(s) of type " ++
    intercalate ", " (map ppType got) ++ "."
  show (InvalidFunctionArguments fname (Just expected) got) =
    "Function '" ++ nameToString fname ++ "' expected argument(s) of type " ++
    intercalate ", " (map ppType expected) ++
    " but got argument(s) of type " ++
    intercalate ", " (map ppType got) ++ "."
  show (IndexOutOfBounds pos arrsz i) =
    "Array index " ++ show i ++ " out of bounds of array size " ++ show arrsz ++ " at " ++ locStr pos ++ "."
  show (NegativeIota pos n) =
    "Argument " ++ show n ++ " to iota at " ++ locStr pos ++ " is negative."
  show (NegativeReplicate pos n) =
    "Argument " ++ show n ++ " to replicate at " ++ locStr pos ++ " is negative."
  show (TypeError pos s) =
    "Type error at " ++ locStr pos ++ " in " ++ s ++ " during interpretation.  This implies a bug in the type checker."
  show (InvalidArrayShape pos shape newshape) =
    "Invalid array reshaping at " ++ locStr pos ++ ", from " ++ show shape ++ " to " ++ show newshape
  show (ZipError pos lengths) =
    "Array arguments to zip must have same length, but arguments at " ++
    locStr pos ++ " have lenghts " ++ intercalate ", " (map show lengths) ++ "."
  show (AssertFailed loc) =
    "Assertion failed at " ++ locStr loc ++ "."

instance Error InterpreterError where
  strMsg = TypeError noLoc

data L0Env = L0Env { envVtable  :: HM.HashMap VName Value
                   , envFtable  :: HM.HashMap Name ([Value] -> L0M [Value])
                   }

-- | A list of places where @trace@ was called, alongside the
-- prettyprinted value that was passed to it.
type Trace = [(SrcLoc, String)]

newtype L0M a = L0M (ReaderT L0Env
                     (ErrorT InterpreterError
                      (Writer Trace)) a)
  deriving (MonadReader L0Env, MonadWriter Trace, Monad, Applicative, Functor)

runL0M :: L0M a -> L0Env -> (Either InterpreterError a, Trace)
runL0M (L0M m) env = runWriter $ runErrorT $ runReaderT m env

bad :: InterpreterError -> L0M a
bad = L0M . throwError

bindVar :: L0Env -> (Ident, Value) -> L0Env
bindVar env (Ident name _ _,val) =
  env { envVtable = HM.insert name val $ envVtable env }

bindVars :: L0Env -> [(Ident, Value)] -> L0Env
bindVars = foldl bindVar

binding :: [(Ident, Value)] -> L0M a -> L0M a
binding bnds = local (`bindVars` bnds)

lookupVar :: Ident -> L0M Value
lookupVar (Ident vname _ loc) = do
  val <- asks $ HM.lookup vname . envVtable
  case val of Just val' -> return val'
              Nothing   -> bad $ TypeError loc $ "lookupVar " ++ textual vname

lookupFun :: Name -> L0M ([Value] -> L0M [Value])
lookupFun fname = do
  fun <- asks $ HM.lookup fname . envFtable
  case fun of Just fun' -> return fun'
              Nothing   -> bad $ TypeError noLoc $ "lookupFun " ++ textual fname

arrToList :: SrcLoc -> Value -> L0M [Value]
arrToList _ (ArrayVal l _) = return $ elems l
arrToList loc _ = bad $ TypeError loc "arrToList"

arrays :: ArrayShape shape => [TypeBase als shape] -> [[Value]] -> [Value]
arrays [rowtype] vs = [arrayVal (concat vs) rowtype]
arrays ts v =
  zipWith arrayVal (arrays' v) ts
  where arrays' = foldr (zipWith (:)) (replicate (length ts) [])

--------------------------------------------------
------- Interpreting an arbitrary function -------
--------------------------------------------------

-- |  @funFun name args prog@ invokes the @name@ function of program
-- @prog@, with the parameters bound in order to the values in @args@.
-- Returns either an error or the return value of @fun@.
-- Additionally, a list of all calls to the special built-in function
-- @trace@ is always returned.  This is useful for debugging.
--
-- Note that if 'prog' is not type-correct, you cannot be sure that
-- you'll get an error from the interpreter - it may just as well
-- silently return a wrong value.  You are, however, guaranteed that
-- the initial call to 'prog' is properly checked.
runFun :: Name -> [Value] -> Prog -> (Either InterpreterError [Value], Trace)
runFun fname mainargs prog = do
  let ftable = foldl expand builtins $ progFunctions prog
      l0env = L0Env { envVtable = HM.empty
                    , envFtable = ftable
                    }
      argtypes = map ((`setUniqueness` Unique) . valueType) mainargs
      runmain =
        case (funDecByName fname prog, HM.lookup fname ftable) of
          (Nothing, Nothing) -> bad $ MissingEntryPoint fname
          (Just (_,_,fparams,_,_), _)
            | length argtypes == length fparams &&
              and (zipWith subtypeOf argtypes $ map identType fparams) ->
              evalFuncall fname [ Constant v noLoc | v <- mainargs ]
            | otherwise ->
              bad $ InvalidFunctionArguments fname
                    (Just (map (toDecl . identType) fparams))
                    (map toDecl argtypes)
          (_ , Just fun) -> -- It's a builtin function, it'll
                            -- do its own error checking.
            fun mainargs
  runL0M runmain l0env
  where
    -- We assume that the program already passed the type checker, so
    -- we don't check for duplicate definitions.
    expand ftable (name,_,params,body,_) =
      let fun args = binding (zip (map fromParam params) args) $ evalBody body
      in HM.insert name fun ftable

-- | As 'runFun', but throws away the trace.
runFunNoTrace :: Name -> [Value] -> Prog -> Either InterpreterError [Value]
runFunNoTrace = ((.) . (.) . (.)) fst runFun -- I admit this is just for fun.

--------------------------------------------
--------------------------------------------
------------- BUILTIN FUNCTIONS ------------
--------------------------------------------
--------------------------------------------

builtins :: HM.HashMap Name ([Value] -> L0M [Value])
builtins = HM.fromList $ map namify
           [("toReal", builtin "toReal")
           ,("trunc", builtin "trunc")
           ,("sqrt", builtin "sqrt")
           ,("log", builtin "log")
           ,("exp", builtin "exp")
           ,("op not", builtin "op not")
           ,("op ~", builtin "op ~")]
  where namify (k,v) = (nameFromString k, v)

builtin :: String -> [Value] -> L0M [Value]
builtin "toReal" [BasicVal (IntVal x)] =
  return [BasicVal $ RealVal (fromIntegral x)]
builtin "trunc" [BasicVal (RealVal x)] =
  return [BasicVal $ IntVal (truncate x)]
builtin "sqrt" [BasicVal (RealVal x)] =
  return [BasicVal $ RealVal (sqrt x)]
builtin "log" [BasicVal (RealVal x)] =
  return [BasicVal $ RealVal (log x)]
builtin "exp" [BasicVal (RealVal x)] =
  return [BasicVal $ RealVal (exp x)]
builtin "op not" [BasicVal (LogVal b)] =
  return [BasicVal $ LogVal (not b)]
builtin "op ~" [BasicVal (RealVal b)] =
  return [BasicVal $ RealVal (-b)]
builtin fname args =
  bad $ InvalidFunctionArguments (nameFromString fname) Nothing $
        map (toDecl . valueType) args

single :: Value -> [Value]
single v = [v]

evalSubExp :: SubExp -> L0M Value
evalSubExp (Var ident)    = lookupVar ident
evalSubExp (Constant v _) = return v

evalBody :: Body -> L0M [Value]

evalBody (LetPat pat e body _) = do
  v <- evalExp e
  local (`bindVars` zip pat v) $ evalBody body

evalBody (LetWith _ name src idxs ve body pos) = do
  v <- lookupVar src
  idxs' <- mapM evalSubExp idxs
  vev <- evalSubExp ve
  v' <- change v idxs' vev
  binding [(name, v')] $ evalBody body
  where change _ [] to = return to
        change (ArrayVal arr t) (BasicVal (IntVal i):rest) to
          | i >= 0 && i <= upper = do
            let x = arr ! i
            x' <- change x rest to
            return $ ArrayVal (arr // [(i, x')]) t
          | otherwise = bad $ IndexOutOfBounds pos (upper+1) i
          where upper = snd $ bounds arr
        change _ _ _ = bad $ TypeError pos "evalBody Let Id"

evalBody (DoLoop merge loopvar boundexp loopbody letbody pos) = do
  bound <- evalSubExp boundexp
  mergestart <- mapM evalSubExp mergeexp
  case bound of
    BasicVal (IntVal n) -> do
      loopresult <- foldM iteration mergestart [0..n-1]
      local (`bindVars` zip mergepat loopresult) $ evalBody letbody
    _ -> bad $ TypeError pos "evalBody DoLoop"
  where (mergepat, mergeexp) = unzip merge
        iteration mergeval i =
          binding [(loopvar, BasicVal $ IntVal i)] $
            local (`bindVars` zip mergepat mergeval) $
              evalBody loopbody

evalBody (Result _ es _) =
  mapM evalSubExp es

evalExp :: Exp -> L0M [Value]

evalExp (SubExp se) =
  single <$> evalSubExp se

evalExp (TupLit es _) =
  mapM evalSubExp es

evalExp (ArrayLit es rt _) =
  single <$> (arrayVal <$> mapM evalSubExp es <*> pure rt)

evalExp (BinOp Plus e1 e2 (Basic Int) pos) = evalIntBinOp (+) e1 e2 pos
evalExp (BinOp Plus e1 e2 (Basic Real) pos) = evalRealBinOp (+) e1 e2 pos
evalExp (BinOp Minus e1 e2 (Basic Int) pos) = evalIntBinOp (-) e1 e2 pos
evalExp (BinOp Minus e1 e2 (Basic Real) pos) = evalRealBinOp (-) e1 e2 pos
evalExp (BinOp Pow e1 e2 (Basic Int) pos) = evalIntBinOp pow e1 e2 pos
  -- Haskell (^) cannot handle negative exponents, so check for that
  -- explicitly.
  where pow x y | y < 0, x == 0 = error "Negative exponential with zero base"
                | y < 0         = 1 `div` (x ^ (-y))
                | otherwise     = x ^ y
evalExp (BinOp Pow e1 e2 (Basic Real) pos) = evalRealBinOp (**) e1 e2 pos
evalExp (BinOp Times e1 e2 (Basic Int) pos) = evalIntBinOp (*) e1 e2 pos
evalExp (BinOp Times e1 e2 (Basic Real) pos) = evalRealBinOp (*) e1 e2 pos
evalExp (BinOp Divide e1 e2 (Basic Int) pos) = evalIntBinOp div e1 e2 pos
evalExp (BinOp Mod e1 e2 (Basic Int) pos) = evalIntBinOp mod e1 e2 pos
evalExp (BinOp Divide e1 e2 (Basic Real) pos) = evalRealBinOp (/) e1 e2 pos
evalExp (BinOp ShiftR e1 e2 _ pos) = evalIntBinOp shiftR e1 e2 pos
evalExp (BinOp ShiftL e1 e2 _ pos) = evalIntBinOp shiftL e1 e2 pos
evalExp (BinOp Band e1 e2 _ pos) = evalIntBinOp (.&.) e1 e2 pos
evalExp (BinOp Xor e1 e2 _ pos) = evalIntBinOp xor e1 e2 pos
evalExp (BinOp Bor e1 e2 _ pos) = evalIntBinOp (.|.) e1 e2 pos
evalExp (BinOp LogAnd e1 e2 _ pos) = evalBoolBinOp (&&) e1 e2 pos
evalExp (BinOp LogOr e1 e2 _ pos) = evalBoolBinOp (||) e1 e2 pos

evalExp (BinOp Equal e1 e2 _ _) = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  return [BasicVal $ LogVal (v1==v2)]

evalExp (BinOp Less e1 e2 _ _) = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  return [BasicVal $ LogVal (v1<v2)]

evalExp (BinOp Leq e1 e2 _ _) = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  return [BasicVal $ LogVal (v1<=v2)]

evalExp (BinOp _ _ _ _ pos) = bad $ TypeError pos "evalExp Binop"

evalExp (Not e pos) = do
  v <- evalSubExp e
  case v of BasicVal (LogVal b) -> return [BasicVal $ LogVal (not b)]
            _                     -> bad $ TypeError pos "evalExp Not"

evalExp (Negate e pos) = do
  v <- evalSubExp e
  case v of BasicVal (IntVal x)  -> return [BasicVal $ IntVal (-x)]
            BasicVal (RealVal x) -> return [BasicVal $ RealVal (-x)]
            _                      -> bad $ TypeError pos "evalExp Negate"

evalExp (If e1 e2 e3 _ pos) = do
  v <- evalSubExp e1
  case v of BasicVal (LogVal True)  -> evalBody e2
            BasicVal (LogVal False) -> evalBody e3
            _                       -> bad $ TypeError pos "evalExp If"

evalExp (Apply fname args _ loc)
  | "trace" <- nameToString fname = do
  vs <- mapM (evalSubExp . fst) args
  tell [(loc, ppValues vs)]
  return vs

evalExp (Apply fname args _ _) =
  evalFuncall fname $ map fst args

evalExp (Index _ ident idxs pos) = do
  v <- lookupVar ident
  idxs' <- mapM evalSubExp idxs
  single <$> foldM idx v idxs'
  where idx (ArrayVal arr _) (BasicVal (IntVal i))
          | i >= 0 && i <= upper = return $ arr ! i
          | otherwise             = bad $ IndexOutOfBounds pos (upper+1) i
          where upper = snd $ bounds arr
        idx _ _ = bad $ TypeError pos "evalExp Index"

evalExp (Iota e pos) = do
  v <- evalSubExp e
  case v of
    BasicVal (IntVal x)
      | x >= 0    ->
        return [arrayVal (map (BasicVal . IntVal) [0..x-1])
                         (Basic Int :: DeclType)]
      | otherwise ->
        bad $ NegativeIota pos x
    _ -> bad $ TypeError pos "evalExp Iota"

evalExp (Size _ i e pos) = do
  v <- evalSubExp e
  case drop i $ valueShape v of
    [] -> bad $ TypeError pos "evalExp Size"
    n:_ -> return [BasicVal $ IntVal n]

evalExp (Replicate e1 e2 pos) = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  case v1 of
    BasicVal (IntVal x)
      | x >= 0    ->
        return [arrayVal (replicate x v2) $ valueType v2]
      | otherwise -> bad $ NegativeReplicate pos x
    _   -> bad $ TypeError pos "evalExp Replicate"

evalExp (Reshape _ shapeexp arrexp pos) = do
  shape <- mapM (asInt <=< evalSubExp) shapeexp
  arr <- evalSubExp arrexp
  let arrt = toDecl $ subExpType arrexp
      rt = arrayOf arrt (Rank $ length shapeexp-1) (uniqueness arrt)
      reshape (n:rest) vs
        | length vs `mod` n == 0 =
          arrayVal <$> mapM (reshape rest) (chunk (length vs `div` n) vs)
                   <*> pure rt
      reshape [] [v] = return v
      reshape _ _ = bad $ InvalidArrayShape pos (valueShape arr) shape
  single <$> reshape shape (flatten arr)
  where flatten (ArrayVal arr _) = concatMap flatten $ elems arr
        flatten t = [t]
        chunk _ [] = []
        chunk i l = let (a,b) = splitAt i l
                    in a : chunk i b
        asInt (BasicVal (IntVal x)) = return x
        asInt _ = bad $ TypeError pos "evalExp Reshape asInt"

evalExp (Rearrange _ perm arrexp _) =
  single <$> permuteArray perm <$> evalSubExp arrexp

evalExp (Split _ splitexp arrexp pos) = do
  split <- evalSubExp splitexp
  vs <- arrToList pos =<< evalSubExp arrexp
  case split of
    BasicVal (IntVal i)
      | i <= length vs ->
        let (bef,aft) = splitAt i vs
        in return [arrayVal bef rt, arrayVal aft rt]
      | otherwise        -> bad $ IndexOutOfBounds pos (length vs) i
    _ -> bad $ TypeError pos "evalExp Split"
  where rt = rowType $ subExpType arrexp

evalExp (Concat _ arr1exp arr2exp pos) = do
  elems1 <- arrToList pos =<< evalSubExp arr1exp
  elems2 <- arrToList pos =<< evalSubExp arr2exp
  return $ single $ arrayVal (elems1 ++ elems2) $ stripArray 1 $ subExpType arr1exp

evalExp (Copy e _) = single <$> evalSubExp e

evalExp (Assert e loc) = do
  v <- evalSubExp e
  case v of BasicVal (LogVal True) ->
              return [BasicVal Checked]
            _ ->
              bad $ AssertFailed loc

evalExp (Conjoin _ _) = return [BasicVal Checked]

evalExp (Map _ fun arrexps loc) = do
  vss <- mapM (arrToList loc <=< evalSubExp) arrexps
  vs' <- mapM (applyLambda fun) $ transpose vss
  return $ arrays (lambdaReturnType fun) vs'

evalExp (Reduce _ fun inputs loc) = do
  let (accexps, arrexps) = unzip inputs
  startaccs <- mapM evalSubExp accexps
  vss <- mapM (arrToList loc <=< evalSubExp) arrexps
  let foldfun acc x = applyLambda fun $ acc ++ x
  foldM foldfun startaccs (transpose vss)

evalExp (Scan _ fun inputs loc) = do
  let (accexps, arrexps) = unzip inputs
  startvals <- mapM evalSubExp accexps
  vss <- mapM (arrToList loc <=< evalSubExp) arrexps
  (acc, vals') <- foldM scanfun (startvals, []) $ transpose vss
  return $ arrays (map valueType acc) $ reverse vals'
    where scanfun (acc, l) x = do
            acc' <- applyLambda fun $ acc ++ x
            return (acc', acc' : l)

evalExp e@(Filter _ fun arrexp _ loc) = do
  vss <- mapM (arrToList loc <=< evalSubExp) arrexp
  vss' <- filterM filt $ transpose vss
  return $ arrays (typeOf e) vss'
  where filt x = do
          res <- applyLambda fun x
          case res of [BasicVal (LogVal True)] -> return True
                      _                          -> return False

evalExp (Redomap _ _ innerfun accexp arrexps loc) = do
  startaccs <- mapM evalSubExp accexp
  vss <- mapM (arrToList loc <=< evalSubExp) arrexps
  let foldfun acc x = applyLambda innerfun $ acc ++ x
  foldM foldfun startaccs $ transpose vss

evalFuncall :: Name -> [SubExp] -> L0M [Value]
evalFuncall fname args = do
  fun <- lookupFun fname
  args' <- mapM evalSubExp args
  fun args'

evalIntBinOp :: (Int -> Int -> Int) -> SubExp -> SubExp -> SrcLoc -> L0M [Value]
evalIntBinOp op e1 e2 loc = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  case (v1, v2) of
    (BasicVal (IntVal x), BasicVal (IntVal y)) ->
      return [BasicVal $ IntVal (op x y)]
    _ ->
      bad $ TypeError loc "evalIntBinOp"

evalRealBinOp :: (Double -> Double -> Double) -> SubExp -> SubExp -> SrcLoc -> L0M [Value]
evalRealBinOp op e1 e2 loc = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  case (v1, v2) of
    (BasicVal (RealVal x), BasicVal (RealVal y)) ->
      return [BasicVal $ RealVal (op x y)]
    _ ->
      bad $ TypeError loc $ "evalRealBinOp " ++ ppValue v1 ++ " " ++ ppValue v2

evalBoolBinOp :: (Bool -> Bool -> Bool) -> SubExp -> SubExp -> SrcLoc -> L0M [Value]
evalBoolBinOp op e1 e2 loc = do
  v1 <- evalSubExp e1
  v2 <- evalSubExp e2
  case (v1, v2) of
    (BasicVal (LogVal x), BasicVal (LogVal y)) ->
      return [BasicVal $ LogVal (op x y)]
    _ ->
      bad $ TypeError loc $ "evalBoolBinOp " ++ ppValue v1 ++ " " ++ ppValue v2

applyLambda :: Lambda -> [Value] -> L0M [Value]
applyLambda (Lambda params body _ _) args =
  binding (zip (map fromParam params) args) $ evalBody body
