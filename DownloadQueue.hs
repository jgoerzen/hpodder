{- hpodder component
Copyright (C) 2006-2008 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module     : DownloadQueue
   Copyright  : Copyright (C) 2006-2008 John Goerzen
   License    : GNU GPL, version 2 or above

   Maintainer : John Goerzen <jgoerzen@complete.org>
   Stability  : provisional
   Portability: portable

Written by John Goerzen, jgoerzen\@complete.org

-}

module DownloadQueue(DownloadEntry(..),
                     DownloadQueue(..),
                     DLAction(..),
                     easyDownloads,
                     runDownloads
                    ) where
import Download
import System.Cmd.Utils
import Data.Maybe.Utils
import System.Posix.Process
import Database.HDBC(handleSqlError)
import Config
import Utils
import System.Log.Logger
import Text.Printf
import System.Exit
import System.IO
import System.Directory
import System.Posix.Files
import System.Posix.Signals
import Data.Hash.MD5
import Data.Progress.Tracker
import Data.Progress.Meter
import Data.Quantity
import Network.URI
import Data.List
import Control.Concurrent.MVar
import Control.Concurrent
import Data.Char
import Control.Monad(when)

d = debugM "downloadqueue"
i = infoM "downloadqueue"

data DownloadEntry a = 
    DownloadEntry {dlurl :: String,
                   dlname :: String,
                   usertok :: a,
                   dlprogress :: Progress}

data DownloadQueue a =
    DownloadQueue {pendingHosts :: [(String, [DownloadEntry a])],
                   -- activeDownloads :: (DownloadEntry, DownloadTok),
                   basePath :: FilePath,
                   allowResume :: Bool,
                   callbackFunc :: (DownloadEntry a -> DLAction -> IO ()),
                   completedDownloads :: [(DownloadEntry a, DownloadTok, Result)]}

data DLAction = DLStarted DownloadTok | DLEnded (DownloadTok, ProcessStatus, Result, String)
              deriving (Eq, Show)

groupByHost :: [DownloadEntry a] -> [(String, [DownloadEntry a])]
groupByHost dllist =
    combineGroups .
    groupBy (\(host1, _) (host2, _) -> host1 == host2) . sortBy sortfunc .
    map (\(x, y) -> (map toLower x, y)) . -- lowercase the hostnames
    map conv $ dllist
    where sortfunc (a, _) (b, _) = compare a b
          conv de = case parseURI (dlurl de) of
                      Nothing -> ("", de)
                      Just x -> case uriAuthority x of
                                  Nothing -> ("", de)
                                  Just ua -> (uriRegName ua, de)
          combineGroups :: [[(String, DownloadEntry a)]] -> [(String, [DownloadEntry a])]
          combineGroups [] = []
          combineGroups (x:xs) =
              (fst . head $ x, map snd x) : combineGroups xs

easyDownloads :: String         -- ^ Name for tracker
              -> IO FilePath    -- ^ Function to get base dir
              -> Bool           -- ^ Allow resuming
              -> (Progress -> IO [DownloadEntry a]) -- ^ Function to get DLentries
              -> (Progress -> ProgressMeter -> DownloadEntry a -> DownloadTok -> IO ()) -- ^ Callback when downloads starts
              -> (Progress -> ProgressMeter -> DownloadEntry a -> DownloadTok -> ProcessStatus -> Result -> IO ()) -- ^ Callback that gets called after the download is complete
              -> IO ()
                 
easyDownloads ptname bdfunc allowresume getentryfunc procStart procFinish =
    do maxthreads <- getMaxThreads
       progressinterval <- getProgressInterval
       basedir <- bdfunc

       pt <- newProgress ptname 0
       meter <- newMeter pt "B" 80 (renderNums binaryOpts 0)
       meterthread <- autoDisplayMeter meter progressinterval 
                      (displayMeter stdout)

       dlentries <- getentryfunc pt

       runDownloads (callback pt meter) basedir allowresume dlentries 
                    maxthreads

       killAutoDisplayMeter meter meterthread
       finishP pt
       displayMeter stdout meter
       putStrLn ""

    where callback pt meter dlentry (DLStarted dltok) =
                 do addComponent meter (dlprogress dlentry)
                    procStart pt meter dlentry dltok
          callback pt meter dlentry (DLEnded (dltok, status, result, msg)) =
              do removeComponent meter (dlname dlentry)
                 when (msg /= "")
                      (writeMeterString stderr meter $
                       " *** " ++ dlname dlentry ++ ": Message on " ++ 
                       tokurl dltok ++ ":\n" ++ msg ++ "\n")
                 procFinish pt meter dlentry dltok status result
                 finishP (dlprogress dlentry)

runDownloads :: (DownloadEntry a -> DLAction -> IO ()) -> -- Callback when a download starts or stops
                  FilePath ->   --  Base path
                  Bool ->       -- Whether or not to allow resume
                  [DownloadEntry a] -> --  Items to download
                  Int ->        --  Max number of download threads
                  IO [(DownloadEntry a, DownloadTok, Result)] -- The completed DLs
runDownloads callbackfunc basefp resumeOK delist maxthreads =
    do oldsigs <- blocksignals
       --print (map (\(h, el) -> (h, map dlurl el)) $ groupByHost delist)
       dqmvar <- newMVar $ DownloadQueue {pendingHosts = groupByHost delist,
                                          completedDownloads = [],
                                          basePath = basefp,
                                          allowResume = resumeOK,
                                          callbackFunc = callbackfunc}
       semaphore <- newQSem 0 -- Used by threads to signal they're done
       mapM_ (\_ -> forkIO (handleSqlError $ childthread dqmvar semaphore)) [1..maxthreads]
       mapM_ (\_ -> waitQSem semaphore) [1..maxthreads]
       restoresignals oldsigs
       withMVar dqmvar (\dq -> return (completedDownloads dq))

childthread :: MVar (DownloadQueue a) -> QSem -> IO ()
childthread dqmvar semaphore =
    do workdata <- getworkdata
       if length(workdata) == 0
          then signalQSem semaphore        -- We're done!
          else do processChildWorkData workdata
                  childthread dqmvar semaphore -- And look for more hosts
    where getworkdata = modifyMVar dqmvar $ \dq ->
             do case pendingHosts dq of
                  [] -> return (dq, [])
                  (x:xs) -> return (dq {pendingHosts = xs}, snd x)

          getProcessStatusWithDelay pid =
              do status <- getProcessStatus False False pid
                 case status of
                   Nothing -> do threadDelay 1000000
                                 getProcessStatusWithDelay pid
                   Just x -> return x
          processChildWorkData [] = return []
          processChildWorkData (x:xs) = 
              do (basefp, resumeOK, callback) <- withMVar dqmvar 
                             (\dq -> return (basePath dq, allowResume dq,
                                            callbackFunc dq))
                 dltok <- startGetURL (dlurl x) basefp resumeOK
                 callback x (DLStarted dltok)
                 status <- getProcessStatusWithDelay (tokpid dltok)
                 result <- finishGetURL dltok status
                 messages <- readFile (tokpath dltok ++ ".msg")

                 -- Add to the completed DLs list.  Also do callback here
                 -- so it's within the lock.  Handy to prevent simultaneous
                 -- DB updates.
                 modifyMVar_ dqmvar $ \dq -> 
                     do callback x (DLEnded (dltok, status, result, messages))
                        -- Delete the messages file now that we don't
                        -- care about it anymore
                        catchSome (removeFile (tokpath dltok ++ ".msg"))
                              (\_ -> return ())
                        return (dq {completedDownloads = 
                                        (x, dltok, result) :
                                        completedDownloads dq})
                 processChildWorkData xs     -- Do the next one

blocksignals = 
    do let sigset = addSignal sigCHLD emptySignalSet
       oldset <- getSignalMask
       blockSignals sigset
       return oldset

restoresignals = setSignalMask