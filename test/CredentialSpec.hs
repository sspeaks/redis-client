module Main where

import           AppConfig        (RunState (..), defaultRunState)
import           CredentialConfig (rejectCredentialArguments,
                                   resolveRedisPasswordFrom)
import           Data.List        (isInfixOf)
import           FillProcess      (buildChildArgs)
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
