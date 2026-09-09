module Main where

import           FlushConfirmation
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "canonicalFlushTarget" $ do
    it "includes the effective plaintext standalone target and scope" $
      canonicalFlushTarget "localhost" Nothing False False
        `shouldBe` "redis://localhost:6379?tls=false&scope=single-node"

    it "includes the effective TLS cluster target and all-primary scope" $
      canonicalFlushTarget "redis.example" Nothing True True
        `shouldBe` "redis+cluster://redis.example:6380?tls=true&scope=all-primaries"

    it "brackets IPv6 hosts and preserves an explicit port" $
      canonicalFlushTarget "2001:db8::1" (Just 7000) False True
        `shouldBe` "redis+cluster://[2001:db8::1]:7000?tls=false&scope=all-primaries"

  describe "confirmation policy" $ do
    let target = "redis://localhost:6379?tls=false&scope=single-node"

    it "rejects a missing non-interactive acknowledgement" $
      nonInteractiveConfirmation Nothing target `shouldSatisfy` isLeft

    it "rejects a mismatched non-interactive acknowledgement" $
      nonInteractiveConfirmation (Just "redis://localhost:6380?tls=false&scope=single-node") target
        `shouldSatisfy` isLeft

    it "accepts only an exact non-interactive acknowledgement" $
      nonInteractiveConfirmation (Just target) target `shouldBe` Right ()

    it "rejects interactive EOF cancellation and mismatched input" $ do
      interactiveConfirmation Nothing target `shouldSatisfy` isLeft
      interactiveConfirmation (Just "no") target `shouldSatisfy` isLeft

    it "accepts an exact interactive response" $
      interactiveConfirmation (Just target) target `shouldBe` Right ()

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
