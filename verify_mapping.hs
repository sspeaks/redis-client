#!/usr/bin/env runhaskell
{-# LANGUAGE OverloadedStrings #-}

-- Verification script to check that the cluster_slot_mapping.txt file is correct
-- by recalculating the slot for each string and comparing to the expected slot.

import qualified Data.ByteString.Char8 as BS
import           Data.Word             (Word16)
import           System.Exit           (exitFailure, exitSuccess)
import           System.IO             (hPutStrLn, stderr)
import           Crc16                 (crc16)

-- Read the mapping file and verify each entry
main :: IO ()
main = do
  putStrLn "Reading cluster_slot_mapping.txt..."
  content <- readFile "cluster_slot_mapping.txt"
  let entries = lines content
  putStrLn $ "Found " ++ show (length entries) ++ " entries"
  
  putStrLn "\nVerifying each mapping..."
  results <- mapM verifyEntry entries
  
  let errors = [e | e@(False, _, _, _) <- results]
  
  if null errors
    then do
      putStrLn $ "\n✓ All " ++ show (length entries) ++ " mappings verified successfully!"
      putStrLn "\nSample verified mappings:"
      mapM_ showSample [0, 1, 100, 1000, 8000, 16383]
      putStrLn "\nMapping file is correct!"
      exitSuccess
    else do
      hPutStrLn stderr $ "\n❌ Found " ++ show (length errors) ++ " errors:"
      mapM_ printError (take 10 errors)
      exitFailure
  where
    verifyEntry :: String -> IO (Bool, Word16, String, Word16)
    verifyEntry line = do
      let [slotStr, keyStr] = words line
          expectedSlot = read slotStr :: Word16
          key = BS.pack keyStr
      
      actualSlot <- crc16 key
      return (expectedSlot == actualSlot, expectedSlot, keyStr, actualSlot)
    
    printError :: (Bool, Word16, String, Word16) -> IO ()
    printError (_, expected, key, actual) =
      hPutStrLn stderr $ "  Slot " ++ show expected ++ " -> '" ++ key ++ "' -> " ++ show actual
    
    showSample :: Word16 -> IO ()
    showSample slot = do
      content <- readFile "cluster_slot_mapping.txt"
      let entries = lines content
      case filter (\line -> read (head $ words line) == slot) entries of
        (entry:_) -> do
          let [slotStr, keyStr] = words entry
          putStrLn $ "  Slot " ++ slotStr ++ " -> '" ++ keyStr ++ "'"
        [] -> return ()
