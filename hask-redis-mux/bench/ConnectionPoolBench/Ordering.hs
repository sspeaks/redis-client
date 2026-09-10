module ConnectionPoolBench.Ordering
  ( finishOrder,
    prependOrder,
    registrationsByNode,
  )
where

import           Data.List       (foldl')
import qualified Data.Map.Strict as Map

prependOrder :: Ord key => key -> value -> Map.Map key [value] -> Map.Map key [value]
prependOrder key value = Map.insertWith (++) key [value]

finishOrder :: Map.Map key [value] -> Map.Map key [value]
finishOrder = Map.map reverse

registrationsByNode :: Ord key => [(value, key)] -> Map.Map key [value]
registrationsByNode = finishOrder . foldl' register Map.empty
  where
  register orders (value, key) = prependOrder key value orders
