{- Copyright 2013-2018 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE RankNTypes #-}

module StandardModules.Mappers.Bwa
    ( hasValidIndex
    , createIndex
    , callMapper
    ) where

import           System.Process (proc, readProcessWithExitCode)
import           System.Exit (ExitCode(..))
import           System.Directory (doesFileExist)
import           System.Posix (getFileStatus, fileSize, FileOffset)
import           System.Path (splitExt)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as BL8

import qualified Data.Conduit.Process as CP
import qualified Data.Conduit.List as CL
import qualified Data.Conduit as C
import           Control.Monad.Extra (allM)
import           Control.Exception (bracket_)
import           GHC.Conc (getNumCapabilities, setNumCapabilities)

import Output
import NGLess
import Configuration
import NGLess.NGLEnvironment
import Dependencies.Versions (bwaVersion)
import FileManagement (bwaBin)

-- | Appends bwa version to the index such that different versions
-- of bwa use different indices
indexPrefix :: FilePath -> NGLessIO FilePath
indexPrefix base = do
    let (basename, ext) = splitExt base
    return $ basename ++ "-bwa-" ++ bwaVersion ++ ext

-- | Checks whether all necessary files are present for a BWA index
-- Does not change any file on disk.
hasValidIndex :: FilePath -> NGLessIO Bool
hasValidIndex basepath = do
    base <- indexPrefix basepath
    let indexRequiredFormats = [".amb",".ann",".bwt",".pac",".sa"]
    liftIO $ allM (doesFileExist . (base ++)) indexRequiredFormats

-- BWA's default indexing parameters are quite conservative. This leads to
-- a small memory footprint at the cost of more CPU hours.
-- With large databases (~100GB) default settings require over 2 weeks of
-- CPU time. Increasing the default blocksize will increase the memory
-- footprint but will reduce indexing time 3 to 6 fold.
--
-- This patch increases the blocksize to roughly 1/10th of the filesize.
-- The memory footprint should be about the size of the database.
--
-- As per https://github.com/lh3/bwa/issues/104 this patch may become
-- obsolete once this functionality is built into bwa.
--
-- | Checks whether we should customize bwa's indexing blocksize
customBlockSize :: FilePath -> IO [String]
customBlockSize path = sizeAsParam . fileSize <$> getFileStatus path

sizeAsParam :: FileOffset -> [String]
sizeAsParam size
    | size >= minimalsize = ["-b", show $ div size factor]
    | otherwise = []
        where minimalsize = 100*1000*1000 -- 100MB - if smaller, use software's default
              factor = 10

-- | Creates bwa index on disk
createIndex :: FilePath -> NGLessIO ()
createIndex fafile = do
    outputListLno' InfoOutput ["Start BWA index creation for ", fafile]
    blocksize <- liftIO $ customBlockSize fafile
    prefix <- indexPrefix fafile
    bwaPath <- bwaBin
    (exitCode, out, err) <- liftIO $
        readProcessWithExitCode bwaPath (["index"] ++ blocksize ++ ["-p", prefix, fafile]) []
    outputListLno' DebugOutput ["BWA-index stderr: ", err]
    outputListLno' DebugOutput ["BWA-index stdout: ", out]
    case exitCode of
        ExitSuccess -> return ()
        ExitFailure _err -> throwSystemError err

callMapper :: FilePath -> [FilePath] -> [String] -> C.ConduitT B.ByteString C.Void IO a -> NGLessIO a
callMapper refIndex fps extraArgs outC = do
    outputListLno' InfoOutput ["Starting mapping to ", refIndex]
    bwaPath <- bwaBin
    refIndex' <- indexPrefix refIndex
    numCapabilities <- liftIO getNumCapabilities
    strictThreads <- nConfStrictThreads <$> nglConfiguration
    let bwathreads
            | strictThreads && numCapabilities > 1 = numCapabilities - 1
            | otherwise = numCapabilities
        cmdargs =  concat [["mem", "-t", show bwathreads], extraArgs, [refIndex'], fps]
        with1Thread :: IO a -> IO a
        with1Thread act
            | strictThreads = bracket_
                                (setNumCapabilities 1)
                                (setNumCapabilities numCapabilities)
                                act
            | otherwise = act

    outputListLno' TraceOutput ["Calling: ", unwords (bwaPath:cmdargs)]
    let cp = proc bwaPath cmdargs
    (exitCode, out, err) <- liftIO . with1Thread $
            CP.sourceProcessWithStreams cp
                (return ()) -- stdin
                outC -- stdout
                CL.consume -- stderr
    let err' = BL8.unpack $ BL8.fromChunks err
    outputListLno' DebugOutput ["BWA info: ", err']
    case exitCode of
        ExitSuccess -> do
            outputListLno' InfoOutput ["Finished mapping to ", refIndex]
            return out
        ExitFailure code ->
            throwSystemError $ concat ["Failed mapping\n",
                            "Executable used::\t", bwaPath,"\n",
                            "Command line was::\n\t", unwords cmdargs, "\n",
                            "Bwa error code was ", show code, ".\n",
                            "Bwa stderr: ", err']

