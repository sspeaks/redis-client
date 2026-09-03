module Main where

import           AppConfig         (RunState (..), defaultRunState)
import           Control.Exception (IOException, displayException, try)
import           CredentialConfig  (rejectCredentialArguments,
                                    resolveRedisPasswordFrom)
import           Data.List         (isInfixOf)
import           FillProcess       (buildChildArgs)
import           System.IO.Error   (doesNotExistErrorType, mkIOError,
                                    permissionErrorType)
import           Test.Hspec

syntheticJwt :: String
syntheticJwt = "eyJhbGciOiJub25lIn0.eyJvaWQiOiJ0ZXN0LXVzZXJfMSJ9.c2lnbmF0dXJlLXNhZmU"

main :: IO ()
main = hspec $ do
  describe "credential argument rejection" $ do
    mapM_ rejectsWithoutEcho
      [ ["cli", "-a", syntheticJwt]
      , ["cli", "-a" ++ syntheticJwt]
      , ["cli", "--password", syntheticJwt]
      , ["cli", "--password=" ++ syntheticJwt]
      ]

    it "accepts arguments without credential options" $
      rejectCredentialArguments ["cli", "-h", "localhost"] `shouldBe` Right ()

  describe "credential resolution" $ do
    it "prefers the credential file over the environment value" $ do
      password <- resolveRedisPasswordFrom
        (Just "/secure/credential")
        (Just "environment-value")
        (\_ -> pure "file-value\n")
      password `shouldBe` "file-value"

    it "uses the environment value when no file is configured" $ do
      password <- resolveRedisPasswordFrom Nothing (Just syntheticJwt) (\_ -> pure "")
      password `shouldBe` syntheticJwt

    it "rejects an empty credential file" $
      resolveRedisPasswordFrom (Just "/secure/credential") Nothing (\_ -> pure "\n")
        `shouldThrow` anyIOException

    it "does not disclose a missing credential path or fallback environment credential" $ do
      let configuredPath = "/secure/missing-credential"
          fallbackCredential = "fallback-environment-credential"
      result <- try $ resolveRedisPasswordFrom
        (Just configuredPath)
        (Just fallbackCredential)
        (\path -> ioError (mkIOError doesNotExistErrorType fallbackCredential Nothing (Just path)))
      case result of
        Left exception -> do
          let message = displayException (exception :: IOException)
          message `shouldContain` "Unable to read Redis credential file"
          message `shouldSatisfy` not . isInfixOf configuredPath
          message `shouldSatisfy` not . isInfixOf fallbackCredential
        Right _ -> expectationFailure "missing credential file was accepted"

    it "does not disclose an unreadable credential path or fallback environment credential" $ do
      let configuredPath = "/secure/unreadable-credential"
          fallbackCredential = "fallback-environment-credential"
      result <- try $ resolveRedisPasswordFrom
        (Just configuredPath)
        (Just fallbackCredential)
        (\path -> ioError (mkIOError permissionErrorType fallbackCredential Nothing (Just path)))
      case result of
        Left exception -> do
          let message = displayException (exception :: IOException)
          message `shouldContain` "Unable to read Redis credential file"
          message `shouldSatisfy` not . isInfixOf configuredPath
          message `shouldSatisfy` not . isInfixOf fallbackCredential
        Right _ -> expectationFailure "unreadable credential file was accepted"

  describe "parallel fill child arguments" $ do
    it "never copies the credential into child argv" $ do
      let state = defaultRunState
            { host = "localhost"
            , password = syntheticJwt
            , username = "entra-object-id"
            }
          args = buildChildArgs state 2 3
      args `shouldSatisfy` (\values -> syntheticJwt `notElem` values)
      args `shouldSatisfy` (\values -> "-a" `notElem` values)
      args `shouldSatisfy` (\values -> "--password" `notElem` values)
      unwords args `shouldSatisfy` not . isInfixOf syntheticJwt

rejectsWithoutEcho :: [String] -> Spec
rejectsWithoutEcho args =
  it "rejects a legacy credential argv form without echoing its value" $
    case rejectCredentialArguments args of
      Left message -> message `shouldSatisfy` not . isInfixOf syntheticJwt
      Right ()     -> expectationFailure "credential-bearing argv was accepted"
