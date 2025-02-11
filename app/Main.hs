module Main where

import Data.List (zipWith)

fibb = 0:1:zipWith (+) fibb (tail fibb)

main :: IO ()
main = print $ fibb !! 10000
