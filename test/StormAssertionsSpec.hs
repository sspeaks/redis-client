{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Exception          (AsyncException (ThreadKilled),
                                             SomeException, fromException,
                                             throwIO, try)
import           Data.List                  (isInfixOf)
import           Database.Redis.Resp        (RespData (..))

import           LibraryE2E.StormAssertions (commandFailure, trySynchronous)

import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "storm failure accounting" $ do
    it "accepts only the expected command response" $ do
      commandFailure 3 "SET" "storm-t3-7" (RespSimpleString "OK")
        (Right (RespSimpleString "OK"))
        `shouldBe` []

    it "records unexpected responses with thread, operation, key, and actual result" $ do
      let failures = commandFailure 3 "GET" "storm-t3-7"
            (RespBulkString "expected") (Right RespNullBulkString)
      failures `shouldSatisfy` any (isInfixOf "thread=3")
      failures `shouldSatisfy` any (isInfixOf "operation=GET")
      failures `shouldSatisfy` any (isInfixOf "key=\"storm-t3-7\"")
      failures `shouldSatisfy` any (isInfixOf "Right NULL")

    it "records synchronous command exceptions and rethrows asynchronous cancellation" $ do
      synchronous <- trySynchronous (throwIO $ userError "connection lost")
        :: IO (Either SomeException RespData)
      commandFailure 1 "GET" "storm-t1-1" (RespBulkString "value") synchronous
        `shouldSatisfy` any (isInfixOf "connection lost")

      cancelled <- try
        (trySynchronous (throwIO ThreadKilled) :: IO (Either SomeException ()))
        :: IO (Either SomeException (Either SomeException ()))
      case cancelled of
        Left exception ->
          (fromException exception :: Maybe AsyncException) `shouldBe` Just ThreadKilled
        Right _ ->
          expectationFailure "trySynchronous swallowed asynchronous cancellation"
