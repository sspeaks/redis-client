module Main where

import           Database.Redis.Client.TLSConfig (parseTLSVerificationBypass)
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "parseTLSVerificationBypass" $ do
    it "enables certificate verification bypass only for exactly 1" $
      parseTLSVerificationBypass (Just "1") `shouldBe` Right True

    mapM_ keepsVerificationEnabled
      [ Nothing
      , Just ""
      , Just "0"
      , Just "false"
      ]

    mapM_ rejectsInvalidValue
      [ "true"
      , "TRUE"
      , "yes"
      , "01"
      , " false "
      ]

keepsVerificationEnabled :: Maybe String -> Spec
keepsVerificationEnabled value =
  it ("keeps certificate verification enabled for " ++ show value) $
    parseTLSVerificationBypass value `shouldBe` Right False

rejectsInvalidValue :: String -> Spec
rejectsInvalidValue value =
  it ("rejects invalid value " ++ show value) $
    case parseTLSVerificationBypass (Just value) of
      Left message -> do
        message `shouldContain` "REDIS_CLIENT_TLS_INSECURE"
        message `shouldContain` "exactly 1"
      Right _ -> expectationFailure "invalid TLS verification bypass value was accepted"
