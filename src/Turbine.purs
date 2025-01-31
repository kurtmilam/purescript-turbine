module Turbine
  ( Component
  , runComponent
  , modelView
  , merge
  , (</>)
  , dynamic
  , use
  , component
  , ComponentResult
  , output
  , class Key
  , keyNoop
  , list
  , class MapRecord
  , mapRecordBuilder
  , static
  , withStatic
  ) where

import Prelude

import Control.Apply (lift2)
import Data.Function.Uncurried (Fn2, runFn2, Fn3, runFn3)
import Data.Symbol (class IsSymbol, SProxy(..))
import Effect (Effect)
import Effect.Class (class MonadEffect)
import Effect.Uncurried (EffectFn2, runEffectFn2)
import Hareactive.Types (Behavior, Now)
import Prim.Row (class Union)
import Prim.Row as Row
import Prim.RowList as RL
import Record as R
import Record.Builder (Builder)
import Record.Builder as Builder
import Type.Data.RowList (RLProxy(..))

foreign import data Component :: Type -> Type -> Type

-- Component instances

instance semigroupComponent :: Semigroup o => Semigroup (Component a o) where
  append = lift2 append

instance monoidComponent :: (Monoid a, RL.RowToList row RL.Nil) => Monoid (Component { | row } a) where
  mempty = pure mempty

instance functorComponent :: Functor (Component a) where
  map = runFn2 _map

foreign import _map :: forall a o p. Fn2 (o -> p) (Component a o) (Component a p)

instance applyComponent :: Apply (Component a) where
  apply = runFn2 _apply

foreign import _apply :: forall a o p. Fn2 (Component a (o -> p)) (Component a o) (Component a p)

-- Components where the first type argument is `{}` form an applicative. `pure
-- a` returns a component that does nothing but with the empty record `{}` as
-- explicit output and with `a` as output.
instance applicativeComponent :: (RL.RowToList row RL.Nil) => Applicative (Component { | row }) where
  pure = _pure

foreign import _pure :: forall a row. RL.RowToList row RL.Nil => a -> Component { | row } a

instance bindComponent :: Bind (Component a) where
  bind = runFn2 _bind

foreign import _bind :: forall a o p. Fn2 (Component a o) (o -> Component a p) (Component a p)

instance monadComponent :: (RL.RowToList row RL.Nil) => Monad (Component { | row })

-- | Runs an `Effect` inside a `Component`. The side-effect will be executed
-- | when the `Component` is being run.
instance monadEffectComponent :: (RL.RowToList row RL.Nil) => MonadEffect (Component { | row }) where
  liftEffect = liftEffectComponent

foreign import liftEffectComponent :: forall a row. RL.RowToList row RL.Nil => Effect a -> Component { | row } a

modelView :: forall a o p. (o -> Now p) -> (p -> Component a o) -> Component p {}
modelView m v = runFn2 _modelView m v

foreign import _modelView :: forall a o p. Fn2 (o -> Now p) (p -> Component a o) (Component p {})

runComponent :: forall a o. String -> Component a o -> Effect Unit
runComponent = runEffectFn2 _runComponent

foreign import _runComponent :: forall a o. EffectFn2 String (Component a o) Unit

-- | Turns a behavior of a component into a component of a behavior. This
-- | function is used to create dynamic HTML where the structure of the HTML
-- | should change over time.
-- |
-- | ```purescript
-- | dynamic (map (\b -> if b else (div {} ) then) behavior)
-- | ```
foreign import dynamic :: forall a o. Behavior (Component a o) -> Component (Behavior o) {}

-- | Type class implemented by `Int`, `Number`, and `String`. Used to represent
-- | overloads.
class Key a where
  keyNoop :: a -> a

instance keyInt :: Key Int where
  keyNoop = identity

instance keyNumber :: Key Number where
  keyNoop = identity

instance keyString :: Key String where
  keyNoop = identity

list :: forall a b o k. Key k =>
  (a -> Component b o) -> Behavior (Array a) -> (a -> k) -> Component (Behavior (Array o)) {}
list = runFn3 _list

foreign import _list :: forall a b o k. Key k =>
  Fn3 (a -> Component b o) (Behavior (Array a)) (a -> k) (Component (Behavior (Array o)) {})

-- | Combines two components and merges their selected output.
merge :: forall a o b p q. Union o p q => Component a { | o } -> Component b { | p } -> Component {} { | q }
merge = runFn2 _merge

foreign import _merge :: forall a o b p q. Union o p q => Fn2 (Component a { | o }) (Component b { | p }) (Component {} { | q })
infixl 0 merge as </>

-- | Copies non-selected output into selected output.
-- |
-- | This function is often used in infix form as in the following example.
-- |
-- | ```purescript
-- | button (text "Fire missiles!") `use` (\o -> { fireMissiles })
-- | ```
use :: forall a o p q. Union o p q => Component a { | o } -> (a -> { | p }) -> Component {} { | q }
use = runFn2 _use

foreign import _use :: forall a o p q. Union o p q => Fn2 (Component a { | o }) (a -> { | p }) (Component {} { | q })

type ComponentResult a o p =
  { component :: Component a o
  , available :: p
  }

output :: forall a o p f. Applicative f => Component a o -> p -> f (ComponentResult a o p)
output c a = pure { component: c, available: a }

foreign import component :: forall a o p. (o -> Now (ComponentResult a o p)) -> Component p {}

mapHeterogenousRecord :: forall row xs f row'
   . RL.RowToList row xs
  => MapRecord xs row f () row'
  => (forall a. a -> f a)
  -> Record row
  -> Record row'
mapHeterogenousRecord f r = Builder.build builder {}
  where
    builder = mapRecordBuilder (RLProxy :: RLProxy xs) f r

class MapRecord (xs :: RL.RowList) (row :: # Type) f (from :: # Type) (to :: # Type)
  | xs -> row f from to where
  mapRecordBuilder :: RLProxy xs -> (forall a. a -> f a) -> Record row -> Builder { | from } { | to }

instance mapRecordCons ::
  ( IsSymbol name
  , Row.Cons name a trash row
  , MapRecord tail row f from from'
  , Row.Lacks name from'
  , Row.Cons name (f a) from' to
  ) => MapRecord (RL.Cons name a tail) row f from to where
  mapRecordBuilder _ f r =
    first <<< rest
    where
      nameP = SProxy :: SProxy name
      val = f $ R.get nameP r
      rest = mapRecordBuilder (RLProxy :: RLProxy tail) f r
      first = Builder.insert nameP val

instance mapRecordNil :: MapRecord RL.Nil row f () () where
  mapRecordBuilder _ _ _ = identity

-- | A helper function used to convert static values in records into constant
-- | behaviors.
-- |
-- | Component functions often takes a large amount of behaviors as input. But,
-- | sometimes all that is required is static values, that is, constant
-- | behaviors. In these cases it can sometimes be tedious to write records like
-- | the following:
-- |
-- | ```purescript
-- | { foo: pure 1, bar: pure 2, baz: pure 3, more: pure 4, fields: pure 5 }
-- | ```
-- |
-- | The `static` function applies `pure` to each value in the given record. As
-- | such, the above can be shortened into the following.
-- |
-- | ```purescript
-- | static { foo: 1, bar: 2, baz: 3, more: 4, fields: 5 }
-- | ```
static :: forall a c row. RL.RowToList row c => MapRecord c row Behavior () a => { | row } -> { | a }
static = mapHeterogenousRecord pure

-- | A function closely related to `static`. Usefull in cases where a component
-- | function is to be supplied with both a set of static values (constant
-- | behaviors). The function applies `static` to its seconds argument and
-- | merges the two records.
-- |
-- | It is often used in infix form as in the following example.
-- |
-- | ```purescript
-- | { foo: behA, bar: behB } `withStatic` { baz: 3, more: 4, fields: 5 }
-- | ```
withStatic :: forall o p q q' p' xs
   . RL.RowToList p xs
  => MapRecord xs p Behavior () p'
  => Union o p' q'
  => Row.Nub q' q
  => { | o } -> { | p } -> { | q }
withStatic a b = R.merge a (static b)
