{-
 -
 - coq backend for act
 -
 - unsupported features:
 - + bytestrings
 - + external storage
 - + specifications for multiple contracts
 -
 -}

{-# Language OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

module Coq where

import Prelude hiding (GT, LT)

import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map.Strict    as M
import qualified Data.List.NonEmpty as NE
import qualified Data.Text          as T
import Data.List (find, groupBy)
import Control.Monad.State

import EVM.ABI
import EVM.Solidity (SlotType(..))
import Syntax
import Syntax.Annotated hiding (Store)

type Store = M.Map Id SlotType
type Fresh = State Int

header :: T.Text
header = T.unlines
  [ "(* --- GENERATED BY ACT --- *)\n"
  , "Require Import Coq.ZArith.ZArith."
  , "Require Import ActLib.ActLib."
  , "Require Coq.Strings.String.\n"
  , "Module " <> strMod <> " := Coq.Strings.String."
  , "Open Scope Z_scope.\n"
  ]

-- | produce a coq representation of a specification
coq :: [Claim] -> T.Text
coq claims =

  header
  <> stateRecord <> "\n\n"
  <> block (evalSeq (claim store') <$> groups behaviours)
  <> block (evalSeq retVal        <$> groups behaviours)
  <> block (evalSeq (base store')  <$> cgroups constructors)
  <> reachable (cgroups constructors) (groups behaviours)

  where

  -- currently only supports one contract
  store' = snd $ head $ M.toList $ head [s | S s <- claims]

  behaviours = filter ((== Pass) . _mode) [a | B a <- claims]

  constructors = filter ((== Pass) . _cmode) [c | C c <- claims]

  groups = groupBy (\b b' -> _name b == _name b')
  cgroups = groupBy (\b b' -> _cname b == _cname b')

  block xs = T.intercalate "\n\n" (concat xs) <> "\n\n"

  stateRecord = T.unlines
    [ "Record " <> stateType <> " : Set := " <> stateConstructor
    , "{ " <> T.intercalate ("\n" <> "; ") (map decl (M.toList store'))
    , "}."
    ] where
    decl (n, s) = (T.pack n) <> " : " <> slotType s



-- | inductive definition of reachable states
reachable :: [[Constructor]] -> [[Behaviour]] -> T.Text
reachable constructors groups = inductive
  reachableType "" (stateType <> " -> " <> stateType <> " -> Prop") body where
  body = concat $
    (evalSeq baseCase <$> constructors)
    <>
    (evalSeq reachableStep <$> groups)

-- | non-recursive constructor for the reachable relation
baseCase :: Constructor -> Fresh T.Text
baseCase (Constructor name _ i@(Interface _ decls) conds _ _ _) =
  fresh name >>= continuation where
  continuation name' =
    return $ name'
      <> baseSuffix <> " : "
      <> universal <> "\n"
      <> constructorBody where
    baseval = parens $ name' <> " " <> envVar <> " " <> arguments i
    constructorBody = (indent 2) . implication . concat $
      [ coqprop <$> conds
      , [reachableType <> " " <> baseval <> " " <> baseval]
      ]
    universal =
      "forall " <> envDecl <> " " <>
      if null decls
      then ""
      else interface i <> ","

-- | recursive constructor for the reachable relation
reachableStep :: Behaviour -> Fresh T.Text
reachableStep (Behaviour name _ _ i conds _ _ _) =
  fresh name >>= continuation where
  continuation name' =
    return $ name'
      <> stepSuffix <> " : forall "
      <> envDecl <> " "
      <> parens (baseVar <> " " <> stateVar <> " : " <> stateType) <> " "
      <> interface i <> ",\n"
      <> constructorBody where
    constructorBody = (indent 2) . implication . concat $
      [ [reachableType <> " " <> baseVar <> " " <> stateVar]
      , coqprop <$> conds
      , [ reachableType <> " " <> baseVar <> " "
          <> parens (name' <> " " <> envVar <> " " <> stateVar <> " " <> arguments i)
        ]
      ]

-- | definition of a base state
base :: Store -> Constructor -> Fresh T.Text
base store (Constructor name _ i _ _ updates _) = do
  name' <- fresh name
  return $ definition name' (envDecl <> " " <> interface i) $
    stateval store (\_ t -> defaultValue t) updates

claim :: Store -> Behaviour -> Fresh T.Text
claim store (Behaviour name _ _ i _ _ rewrites _) = do
  name' <- fresh name
  return $ definition name' (envDecl <> " " <> stateDecl <> " " <> interface i) $
    stateval store (\n _ -> T.pack n <> " " <> stateVar) (updatesFromRewrites rewrites)

-- | inductive definition of a return claim
-- ignores claims that do not specify a return value
retVal :: Behaviour -> Fresh T.Text
retVal (Behaviour name _ _ i conds _ _ (Just r)) =
  fresh name >>= continuation where
  continuation name' = return $ inductive
    (name' <> returnSuffix)
    (envDecl <> " " <> stateDecl <> " " <> interface i)
    (returnType r <> " -> Prop")
    [retname <> introSuffix <> " :\n" <> body] where

    retname = name' <> returnSuffix
    body = indent 2 . implication . concat $
      [ coqprop <$> conds
      , [retname <> " " <> envVar <> " " <> stateVar <> " " <> arguments i <> " " <> typedexp r]
      ]

retVal _ = return ""

-- | produce a state value from a list of storage updates
-- 'handler' defines what to do in cases where a given name isn't updated
stateval
  :: Store
  -> (Id -> SlotType -> T.Text)
  -> [StorageUpdate]
  -> T.Text
stateval store handler updates = T.unwords $ stateConstructor : fmap (valuefor updates) (M.toList store)
  where
  valuefor :: [StorageUpdate] -> (Id, SlotType) -> T.Text
  valuefor updates' (name, t) =
    case find (eqName name) updates' of
      Nothing -> parens $ handler name t
      Just (Update SByteStr _ _) -> error "bytestrings not supported"
      Just (Update _ item e) -> lambda (ixsFromItem item) 0 e (idFromItem item) (flip handler t)

-- | filter by name
eqName :: Id -> StorageUpdate -> Bool
eqName n update = n == idFromUpdate update

-- represent mapping update with anonymous function
lambda :: [TypedExp] -> Int -> Exp a -> Id -> (Id -> T.Text) -> T.Text
lambda [] _ e _ _ = parens $ coqexp e
lambda (TExp argType arg:xs) n e m handler = parens $
  "fun " <> name <> " =>"
  <> " if " <> name <> eqsym <> coqexp arg
  <> " then " <> lambda xs (n + 1) e m handler
  <> " else " <> parens (handler m) <> " " <> lambdaArgs n where
  name = anon <> T.pack (show n)
  lambdaArgs i = T.unwords $ map (\a -> anon <> T.pack (show a)) [0..i]
  eqsym = case argType of
    SInteger -> " =? "
    SBoolean -> " =?? "
    SByteStr -> error "bytestrings not supported"

-- | produce a block of declarations from an interface
interface :: Interface -> T.Text
interface (Interface _ decls) =
  T.unwords $ map decl decls where
  decl (Decl t name) = parens $ T.pack name <> " : " <> abiType t

arguments :: Interface -> T.Text
arguments (Interface _ decls) =
  T.unwords $ map (\(Decl _ name) -> T.pack name) decls

-- | coq syntax for a slot type
slotType :: SlotType -> T.Text
slotType (StorageMapping xs t) =
  T.intercalate " -> " (map abiType (NE.toList xs ++ [t]))
slotType (StorageValue abitype) = abiType abitype

-- | coq syntax for an abi type
abiType :: AbiType -> T.Text
abiType (AbiUIntType _) = "Z"
abiType (AbiIntType _) = "Z"
abiType AbiAddressType = "address"
abiType AbiStringType = strMod <> ".string"
abiType a = error $ show a

-- | coq syntax for a return type
returnType :: TypedExp -> T.Text
returnType (TExp SInteger _) = "Z"
returnType (TExp SBoolean _) = "bool"
returnType (TExp SByteStr _) = error "bytestrings not supported"

-- | default value for a given type
-- this is used in cases where a value is not set in the constructor
defaultValue :: SlotType -> T.Text
defaultValue (StorageMapping xs t) =
  "fun "
  <> T.unwords (replicate (length (NE.toList xs)) "_")
  <> " => "
  <> abiVal t
defaultValue (StorageValue t) = abiVal t

abiVal :: AbiType -> T.Text
abiVal (AbiUIntType _) = "0"
abiVal (AbiIntType _) = "0"
abiVal AbiAddressType = "0"
abiVal AbiStringType = strMod <> ".EmptyString"
abiVal _ = error "TODO: missing default values"

-- | coq syntax for an expression
coqexp :: Exp a -> T.Text

-- booleans
coqexp (LitBool _ True)  = "true"
coqexp (LitBool _ False) = "false"
coqexp (Var _ SBoolean name)  = T.pack name
coqexp (And _ e1 e2)  = parens $ "andb "   <> coqexp e1 <> " " <> coqexp e2
coqexp (Or _ e1 e2)   = parens $ "orb"     <> coqexp e1 <> " " <> coqexp e2
coqexp (Impl _ e1 e2) = parens $ "implb"   <> coqexp e1 <> " " <> coqexp e2
coqexp (Eq _ e1 e2)   = parens $ coqexp e1  <> " =? " <> coqexp e2
coqexp (NEq _ e1 e2)  = parens $ "negb " <> parens (coqexp e1  <> " =? " <> coqexp e2)
coqexp (Neg _ e)      = parens $ "negb " <> coqexp e
coqexp (LT _ e1 e2)   = parens $ coqexp e1 <> " <? "  <> coqexp e2
coqexp (LEQ _ e1 e2)  = parens $ coqexp e1 <> " <=? " <> coqexp e2
coqexp (GT _ e1 e2)   = parens $ coqexp e2 <> " <? "  <> coqexp e1
coqexp (GEQ _ e1 e2)  = parens $ coqexp e2 <> " <=? " <> coqexp e1

-- integers
coqexp (LitInt _ i) = T.pack $ show i
coqexp (Var _ SInteger name)  = T.pack name
coqexp (Add _ e1 e2) = parens $ coqexp e1 <> " + " <> coqexp e2
coqexp (Sub _ e1 e2) = parens $ coqexp e1 <> " - " <> coqexp e2
coqexp (Mul _ e1 e2) = parens $ coqexp e1 <> " * " <> coqexp e2
coqexp (Div _ e1 e2) = parens $ coqexp e1 <> " / " <> coqexp e2
coqexp (Mod _ e1 e2) = parens $ "Z.modulo " <> coqexp e1 <> coqexp e2
coqexp (Exp _ e1 e2) = parens $ coqexp e1 <> " ^ " <> coqexp e2
coqexp (IntMin _ n)  = parens $ "INT_MIN "  <> T.pack (show n)
coqexp (IntMax _ n)  = parens $ "INT_MAX "  <> T.pack (show n)
coqexp (UIntMin _ n) = parens $ "UINT_MIN " <> T.pack (show n)
coqexp (UIntMax _ n) = parens $ "UINT_MAX " <> T.pack (show n)

-- polymorphic
coqexp (TEntry _ w e) = entry e w
coqexp (ITE _ b e1 e2) = parens $ "if "
                               <> coqexp b
                               <> " then "
                               <> coqexp e1
                               <> " else "
                               <> coqexp e2

-- environment values
coqexp (IntEnv _ Caller) = parens (callerVar <> " " <> envVar)

-- unsupported
coqexp (IntEnv _ e) = error $ show e <> ": environment value not yet supported"
coqexp Cat {} = error "bytestrings not supported"
coqexp Slice {} = error "bytestrings not supported"
coqexp (Var _ SByteStr _) = error "bytestrings not supported"
coqexp ByStr {} = error "bytestrings not supported"
coqexp ByLit {} = error "bytestrings not supported"
coqexp ByEnv {} = error "bytestrings not supported"

-- | coq syntax for a proposition
coqprop :: Exp a -> T.Text
coqprop (LitBool _ True)  = "True"
coqprop (LitBool _ False) = "False"
coqprop (And _ e1 e2)  = parens $ coqprop e1 <> " /\\ " <> coqprop e2
coqprop (Or _ e1 e2)   = parens $ coqprop e1 <> " \\/ " <> coqprop e2
coqprop (Impl _ e1 e2) = parens $ coqprop e1 <> " -> " <> coqprop e2
coqprop (Neg _ e)      = parens $ "not " <> coqprop e
coqprop (Eq _ e1 e2)   = parens $ coqexp e1 <> " = "  <> coqexp e2
coqprop (NEq _ e1 e2)  = parens $ coqexp e1 <> " <> " <> coqexp e2
coqprop (LT _ e1 e2)   = parens $ coqexp e1 <> " < "  <> coqexp e2
coqprop (LEQ _ e1 e2)  = parens $ coqexp e1 <> " <= " <> coqexp e2
coqprop (GT _ e1 e2)   = parens $ coqexp e1 <> " > "  <> coqexp e2
coqprop (GEQ _ e1 e2)  = parens $ coqexp e1 <> " >= " <> coqexp e2
coqprop _ = error "ill formed proposition"

-- | coq syntax for a typed expression
typedexp :: TypedExp -> T.Text
typedexp (TExp _ e) = coqexp e

entry :: TStorageItem a -> When -> T.Text
entry (Item SByteStr _ _ _) _    = error "bytestrings not supported"
entry _                     Post = error "TODO: missing support for poststate references in coq backend"
entry item                  _    = case ixsFromItem item of
  []       -> parens $ T.pack (idFromItem item) <> " " <> stateVar
  (ix:ixs) -> parens $ T.pack (idFromItem item) <> " " <> stateVar <> " " <> coqargs (ix :| ixs)

-- | coq syntax for a list of arguments
coqargs :: NonEmpty TypedExp -> T.Text
coqargs (e :| es) =
  typedexp e <> " " <> T.unwords (map typedexp es)

fresh :: Id -> Fresh T.Text
fresh name = state $ \s -> (T.pack (name <> show s), s + 1)

evalSeq :: Traversable t => (a -> Fresh b) -> t a -> t b
evalSeq f xs = evalState (sequence (f <$> xs)) 0

--- text manipulation ---

definition :: T.Text -> T.Text -> T.Text -> T.Text
definition name args value = T.unlines
  [ "Definition " <> name <> " " <> args <> " :="
  , value
  , "."
  ]

inductive :: T.Text -> T.Text -> T.Text -> [T.Text] -> T.Text
inductive name args indices constructors = T.unlines
  [ "Inductive " <> name <> " " <> args <> " : " <> indices <> " :="
  , T.unlines $ ("| " <>) <$> constructors
  , "."
  ]

-- | multiline implication
implication :: [T.Text] -> T.Text
implication xs = "   " <> T.intercalate "\n-> " xs

-- | wrap text in parentheses
parens :: T.Text -> T.Text
parens s = "(" <> s <> ")"

indent :: Int -> T.Text -> T.Text
indent n = T.unlines . fmap (T.replicate n " " <>) . T.lines

--- constants ---

-- | string module name
strMod :: T.Text
strMod  = "Str"

-- | base state name
baseVar :: T.Text
baseVar = "BASE"

stateType :: T.Text
stateType = "State"

stateVar :: T.Text
stateVar = "STATE"

stateDecl :: T.Text
stateDecl = parens $ stateVar <> " : " <> stateType

stateConstructor :: T.Text
stateConstructor = "state"

returnSuffix :: T.Text
returnSuffix = "_ret"

baseSuffix :: T.Text
baseSuffix = "_base"

stepSuffix :: T.Text
stepSuffix = "_step"

introSuffix :: T.Text
introSuffix = "_intro"

reachableType :: T.Text
reachableType = "reachable"

-- | Environment Values

callerVar :: T.Text
callerVar = "CALLER"

callerType :: T.Text
callerType = "address"

envType :: T.Text
envType = "Env"

envVar :: T.Text
envVar = "ENV"

envDecl :: T.Text
envDecl = parens $ envVar <> " : " <> envType

anon :: T.Text
anon = "_binding_"
