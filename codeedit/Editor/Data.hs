{-# LANGUAGE TemplateHaskell, DeriveFunctor, DeriveFoldable, DeriveTraversable, DeriveDataTypeable #-}
module Editor.Data
  ( Definition(..), DefinitionBody(..)
  , DefinitionIRef, DefinitionI, ExpressionIRef(..)
  , FFIName(..)
  , VariableRef(..), variableRefGuid
  , Lambda(..), lambdaParamId, lambdaParamType, lambdaBody
  , Apply(..), applyFunc, applyArg
  , Builtin(..)
  , Leaf(..)
  , ExpressionBody(..)
  , makeApply, makePi, makeLambda
  , makeParameterRef, makeDefinitionRef, makeLiteralInteger
  , Expression(..), eValue, ePayload
  , PureExpression, pureExpression
  , randomizeExpr
  , canonizeParamIds, randomizeParamIds
  , matchExpression
  , subExpressions
  , isDependentPi
  ) where

import Control.Applicative (Applicative(..), liftA2, (<$>))
import Control.Lens ((^.))
import Control.Monad (liftM, liftM2)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.Monad.Trans.State (evalState, state)
import Data.Binary (Binary(..))
import Data.Binary.Get (getWord8)
import Data.Binary.Put (putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Foldable (Foldable(..))
import Data.Maybe (fromMaybe)
import Data.Store.Guid (Guid)
import Data.Store.IRef (IRef)
import Data.Traversable (Traversable(..))
import Data.Typeable (Typeable)
import System.Random (Random, RandomGen, random)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Trans.Reader as Reader
import qualified Data.Foldable as Foldable
import qualified Data.Map as Map
import qualified Data.Store.IRef as IRef
import qualified Data.Traversable as Traversable
import qualified System.Random as Random

data Lambda expr = Lambda
  { _lambdaParamId :: Guid
  , _lambdaParamType :: expr
  , _lambdaBody :: expr
  } deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

data Apply expr = Apply
  { _applyFunc :: expr
  , _applyArg :: expr
  } deriving (Eq, Ord, Show, Functor, Foldable, Traversable)
instance Applicative Apply where
  pure x = Apply x x
  Apply f0 a0 <*> Apply f1 a1 = Apply (f0 f1) (a0 a1)

newtype ExpressionIRef = ExpressionIRef {
  unExpressionIRef :: IRef (ExpressionBody ExpressionIRef)
  } deriving (Eq, Ord, Show, Typeable)

type DefinitionI = Definition ExpressionIRef
type DefinitionIRef = IRef DefinitionI

data VariableRef
  = ParameterRef {-# UNPACK #-} !Guid -- of the lambda/pi
  | DefinitionRef {-# UNPACK #-} !DefinitionIRef
  deriving (Eq, Ord, Show)

data Leaf
  = GetVariable !VariableRef
  | LiteralInteger !Integer
  | Set
  | IntegerType
  | Hole
  deriving (Eq, Ord, Show)

data ExpressionBody expr
  = ExpressionLambda {-# UNPACK #-} !(Lambda expr)
  | ExpressionPi {-# UNPACK #-} !(Lambda expr)
  | ExpressionApply {-# UNPACK #-} !(Apply expr)
  | ExpressionLeaf !Leaf
  deriving (Eq, Ord, Functor, Foldable, Traversable)

makeApply :: expr -> expr -> ExpressionBody expr
makeApply func arg = ExpressionApply $ Apply func arg

makePi :: Guid -> expr -> expr -> ExpressionBody expr
makePi argId argType resultType =
  ExpressionPi $ Lambda argId argType resultType

makeLambda :: Guid -> expr -> expr -> ExpressionBody expr
makeLambda argId argType body =
  ExpressionLambda $ Lambda argId argType body

makeParameterRef :: Guid -> ExpressionBody a
makeParameterRef = ExpressionLeaf . GetVariable . ParameterRef

makeDefinitionRef :: DefinitionIRef -> ExpressionBody a
makeDefinitionRef = ExpressionLeaf . GetVariable . DefinitionRef

makeLiteralInteger :: Integer -> ExpressionBody a
makeLiteralInteger = ExpressionLeaf . LiteralInteger

instance Show expr => Show (ExpressionBody expr) where
  show (ExpressionLambda (Lambda paramId paramType body)) =
    concat ["\\", show paramId, ":", showP paramType, "==>", showP body]
  show (ExpressionPi (Lambda paramId paramType body)) =
    concat ["(", show paramId, ":", showP paramType, ")->", showP body]
  show (ExpressionApply (Apply func arg)) = unwords [showP func, showP arg]
  show (ExpressionLeaf (GetVariable (ParameterRef guid))) = "par:" ++ show guid
  show (ExpressionLeaf (GetVariable (DefinitionRef defI))) = "def:" ++ show (IRef.guid defI)
  show (ExpressionLeaf (LiteralInteger int)) = show int
  show (ExpressionLeaf x) = show x

showP :: Show a => a -> String
showP = parenify . show

parenify :: String -> String
parenify x = concat ["(", x, ")"]

data FFIName = FFIName
  { fModule :: [String]
  , fName :: String
  } deriving (Eq, Ord)

instance Show FFIName where
  show (FFIName path name) = concatMap (++".") path ++ name

data Builtin = Builtin
  { bName :: FFIName
  } deriving (Eq, Ord, Show)

data DefinitionBody expr
  = DefinitionExpression expr
  | DefinitionBuiltin Builtin
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

data Definition expr = Definition
  { defBody :: DefinitionBody expr
  , defType :: expr
  } deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

type PureExpression = Expression ()

data Expression a = Expression
  { _eValue :: ExpressionBody (Expression a)
  , _ePayload :: a
  } deriving (Functor, Eq, Ord, Foldable, Traversable, Typeable)

instance Show a => Show (Expression a) where
  show (Expression body payload) = show body ++ "{" ++ show payload ++ "}"

LensTH.makeLenses ''Expression

pureExpression :: ExpressionBody PureExpression -> PureExpression
pureExpression = (`Expression` ())

variableRefGuid :: VariableRef -> Guid
variableRefGuid (ParameterRef i) = i
variableRefGuid (DefinitionRef i) = IRef.guid i

randomizeExpr :: (RandomGen g, Random r) => g -> Expression (r -> a) -> Expression a
randomizeExpr gen = (`evalState` gen) . Traversable.mapM randomize
  where
    randomize f = fmap f $ state random

canonizeParamIds :: Expression a -> Expression a
canonizeParamIds = randomizeParamIds $ Random.mkStdGen 0

randomizeParamIds :: RandomGen g => g -> Expression a -> Expression a
randomizeParamIds gen =
  (`evalState` gen) . (`runReaderT` Map.empty) . go
  where
    onLambda (Lambda oldParamId paramType body) = do
      newParamId <- lift $ state random
      liftM2 (Lambda newParamId) (go paramType) .
        Reader.local (Map.insert oldParamId newParamId) $ go body
    go (Expression v s) = liftM (`Expression` s) $
      case v of
      ExpressionLambda lambda -> liftM ExpressionLambda $ onLambda lambda
      ExpressionPi lambda -> liftM ExpressionPi $ onLambda lambda
      ExpressionApply (Apply func arg) -> liftM2 makeApply (go func) (go arg)
      gv@(ExpressionLeaf (GetVariable (ParameterRef guid))) ->
        Reader.asks $
        maybe gv makeParameterRef .
        Map.lookup guid
      _ -> return v

-- The returned expression gets the same guids as the left expression
matchExpression ::
  Applicative f =>
  (a -> b -> f c) ->
  (Expression a -> Expression b -> f (Expression c)) ->
  Expression a -> Expression b -> f (Expression c)
matchExpression onMatch onMismatch =
  go Map.empty
  where
    go scope e0@(Expression body0 pl0) e1@(Expression body1 pl1) =
      case (body0, body1) of
      (ExpressionLambda l0, ExpressionLambda l1) ->
        mkExpression . fmap ExpressionLambda $ onLambda l0 l1
      (ExpressionPi l0, ExpressionPi l1) ->
        mkExpression . fmap ExpressionPi $ onLambda l0 l1
      (ExpressionApply (Apply f0 a0), ExpressionApply (Apply f1 a1)) ->
        mkExpression . fmap ExpressionApply $ liftA2 Apply (go scope f0 f1) (go scope a0 a1)
      (ExpressionLeaf gv@(GetVariable (ParameterRef p0)),
       ExpressionLeaf (GetVariable (ParameterRef p1)))
        | p0 == lookupGuid p1 ->
          mkExpression . pure $ ExpressionLeaf gv
      (ExpressionLeaf x, ExpressionLeaf y)
        | x == y -> mkExpression . pure $ ExpressionLeaf x
      _ -> onMismatch e0 $ onGetParamGuids lookupGuid e1
      where
        lookupGuid guid = fromMaybe guid $ Map.lookup guid scope
        mkExpression body = Expression <$> body <*> onMatch pl0 pl1
        onLambda (Lambda p0 pt0 r0) (Lambda p1 pt1 r1) =
          liftA2 (Lambda p0) (go scope pt0 pt1) $
          go (Map.insert p1 p0 scope) r0 r1

onGetParamGuids :: (Guid -> Guid) -> Expression a -> Expression a
onGetParamGuids f (Expression body payload) =
  flip Expression payload $
  case body of
  ExpressionLeaf (GetVariable (ParameterRef getParGuid)) ->
    makeParameterRef $ f getParGuid
  _ -> fmap (onGetParamGuids f) body

subExpressions :: Expression a -> [Expression a]
subExpressions x =
  x : Foldable.concatMap subExpressions (x ^. eValue)

isDependentPi ::
  Expression a -> Bool
isDependentPi (Expression (ExpressionPi (Lambda g _ resultType)) _) =
  any (isGet . Lens.view eValue) $ subExpressions resultType
  where
    isGet (ExpressionLeaf (GetVariable (ParameterRef p))) = p == g
    isGet _ = False
isDependentPi _ = False

derive makeBinary ''ExpressionIRef
derive makeBinary ''FFIName
derive makeBinary ''VariableRef
derive makeBinary ''Lambda
derive makeBinary ''Apply
derive makeBinary ''Leaf
derive makeBinary ''ExpressionBody
derive makeBinary ''Expression
derive makeBinary ''Builtin
derive makeBinary ''DefinitionBody
derive makeBinary ''Definition
LensTH.makeLenses ''Lambda
LensTH.makeLenses ''Apply
