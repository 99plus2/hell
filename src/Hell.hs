{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}

-- | The Hell shell.

module Hell
  (module Hell.Types
  ,module Data.Default
  ,startHell)
  where

import Hell.Types

import Control.Exception
import Control.Monad.Reader
import Control.Monad.Trans
import Data.Default
import Data.Dynamic
import Data.IORef
import Data.List
import Data.Maybe
import System.Console.Haskeline
import System.Console.Haskeline.History
import System.Directory
import System.FilePath

#ifndef WINDOWS
import System.Posix.User
#else
import Hell.Win32
#endif

import GHC hiding (History)
import GHC.Paths hiding (ghc)
import DynFlags

-- | Go to hell.
startHell :: Config -> IO ()
startHell unreadyConfig =
  do home <- io getHomeDirectory
     let config =
           unreadyConfig { configHistory = reifyHome home (configHistory unreadyConfig) }
     runGhc
       (Just libdir)
       (do dflags <- getSessionDynFlags
           void (setSessionDynFlags
                   (setFlags [Opt_ImplicitPrelude, Opt_OverloadedStrings]
                             dflags))
           setImports (configImports config)
           historyRef <- io (readHistory (configHistory config) >>= newIORef)
           username <- io getEffectiveUserName
           runReaderT (runHell repl)
                      (HellState config historyRef username home))

-- | Read-eval-print loop.
repl :: Hell ()
repl =
  do state <- ask
     config <- asks stateConfig
     welcome <- asks (configWelcome . stateConfig)
     unless (null welcome) (haskeline (outputStrLn welcome))
     loop config state

-- | Do the get-line-and-looping.
loop :: Config -> HellState -> Hell b
loop config state = do
  fix (\again ->
         do (mline,history) <- getLineAndHistory config state
            case mline of
              Nothing -> again
              Just line ->
                do historyRef <- asks stateHistory
                   io (writeIORef historyRef history)
                   result <- ghc (runStatement run line)
                   unless (null result)
                          (haskeline (outputStrLn result))
                   io (writeHistory (configHistory config) history)
                   again)
  where run = fromMaybe "" (configRun config)

-- | Get a new line and return it with a new history.
getLineAndHistory :: Config -> HellState -> Hell (Maybe String, History)
getLineAndHistory config state =
  do pwd <- io getCurrentDirectory
     prompt <- prompter (stateUsername state) (stripHome home pwd)
     haskeline (do line <- getInputLine prompt
                   history <- getHistory
                   return (line,history))
  where prompter = configPrompt config
        home = stateHome state

-- | Transform ~/foo to /home/chris/foo.
reifyHome :: FilePath -> String -> FilePath
reifyHome home fp
  | isPrefixOf "~/" fp = (home </> drop 2 fp)
  | otherwise = fp

-- | Strip and replace /home/chris/blah with ~/blah.
stripHome :: FilePath -> FilePath -> FilePath
stripHome home path
  | isPrefixOf home path = "~/" ++ dropWhile (=='/') (drop (length home) path)
  | otherwise            = path

-- | Import the given modules.
setImports :: [String] -> Ghc ()
setImports =
  mapM (fmap IIDecl . parseImportDecl) >=> setContext

-- | Run the given statement.
runStatement :: String -> String -> Ghc String
runStatement run stmt' = do
  result <- gcatch (fmap Right (dynCompileExpr stmt))
                   (\(e::SomeException) -> return (Left e))
  case result of
    Left{} -> runExpression stmt'
    Right compiled ->
      gcatch (fmap ignoreUnit (io (fromDyn compiled (return "Bad compile."))))
             (\(e::SomeException) -> return (show e))

  where stmt = "(" ++ run ++ "(" ++ stmt' ++ ")) >>= return . show :: IO String"
        ignoreUnit "()" = ""
        ignoreUnit x = x

-- | Compile the given expression and evaluate it.
runExpression :: String -> Ghc String
runExpression stmt' = do
  result <- gcatch (fmap Right (dynCompileExpr stmt))
                   (\(e::SomeException) -> return (Left e))
  case result of
    Left err -> return (show err)
    Right compiled ->
      gcatch (io (fromDyn compiled (return "Bad compile.")))
             (\(e::SomeException) -> return (show e))

  where stmt = "return (show (" ++ stmt' ++ ")) :: IO String"

-- | Short-hand utility.
io :: MonadIO m => IO a -> m a
io = Control.Monad.Trans.liftIO

-- | Run a Haskeline action in Hell.
haskeline :: InputT IO a -> Hell a
haskeline m =
  do historyRef <- asks stateHistory
     history <- io (readIORef historyRef)
     io (runInputT defaultSettings
                   (do putHistory history
                       m))

-- | Run a GHC action in Hell.
ghc :: Ghc a -> Hell a
ghc m = Hell (ReaderT (const m))

-- | Set the given flags.
setFlags :: [ExtensionFlag] -> DynFlags -> DynFlags
setFlags xs dflags = foldl xopt_set dflags xs
