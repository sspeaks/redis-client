import           CommandHelp        (renderCommandHelp,
                                     renderReadmeCliReference)
import           System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["help"]   -> putStr renderCommandHelp
    ["readme"] -> putStr renderReadmeCliReference
    _ -> ioError $ userError "Usage: cabal exec runghc -- -iapp scripts/render-cli-reference.hs [help|readme]"
