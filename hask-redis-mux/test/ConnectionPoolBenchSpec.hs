module Main (main) where

import qualified Data.Map.Strict              as Map
import           Test.Hspec

import           ConnectionPoolBench.Ordering

main :: IO ()
main = hspec $ describe "ConnectionPoolBench ordering metric" $ do
  it "preserves registration order for one saturated node" $
    registrationsByNode
      [(waiterIndex, "node") | waiterIndex <- [1 .. 8 :: Int]]
      `shouldBe` Map.singleton "node" [1 .. 8]

  it "preserves independent registration order for interleaved nodes" $
    registrationsByNode
      [ (1 :: Int, "node-a")
      , (2, "node-b")
      , (3, "node-a")
      , (4, "node-b")
      ]
      `shouldBe` Map.fromList
        [ ("node-a", [1, 3])
        , ("node-b", [2, 4])
        ]
