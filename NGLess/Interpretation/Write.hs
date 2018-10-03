{- Copyright 2013-2018 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE FlexibleContexts, CPP #-}

module Interpretation.Write
    ( executeWrite
#ifdef IS_BUILDING_TEST
    , _formatFQOname
#endif
    ) where



import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit.Combinators as C
#ifndef WINDOWS
-- bzlib cannot compile on Windows (as of 2016/07/05)
import qualified Data.Conduit.BZlib as CBZ2
#endif
import           Data.Conduit ((.|))
import           System.Directory (copyFile)
import           Data.Maybe
import           Data.String.Utils (replace, endswith)
import           Control.Monad.IO.Unlift (MonadUnliftIO)
import           Control.Monad (zipWithM_)
import           Control.Monad.Catch (MonadMask)
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           System.IO (Handle, stdout)
import           Data.List (isInfixOf)

import Data.FastQ
import Language
import Configuration
import FileOrStream
import FileManagement (makeNGLTempFile)
import NGLess
import Output
import NGLess.NGLEnvironment
import Utils.Samtools (convertSamToBam, convertBamToSam)
import Utils.Conduit
import Utils.Utils (withOutputFile, fmapMaybeM, moveOrCopy)

{- A few notes:
    There is a transform pass which adds the argument __can_move to write() calls.
    If canMove is True, then we can move the input instead of copying as it
    will no longer be used in the script.

    Decisions on whether to use compression are based on the filenames.

    The filepath "/dev/stdout" is special cased to print to stdout
-}

data WriteOptions = WriteOptions
                { woOFile :: FilePath
                , woFormat :: Maybe T.Text
                , woFormatFlags :: Maybe T.Text
                , woCanMove :: Bool
                , woVerbose :: Bool
                , woComment :: Maybe T.Text
                , woAutoComment :: [AutoComment]
                , woHash :: T.Text
                } deriving (Eq, Show)

withOutputFile' :: (MonadUnliftIO m, MonadIO m, MonadMask m) => FilePath -> (Handle -> m a) -> m a
withOutputFile' "/dev/stdout" = \inner -> inner stdout
withOutputFile' fname = withOutputFile fname

parseWriteOptions :: KwArgsValues -> NGLessIO WriteOptions
parseWriteOptions args = do
    sub <- nConfSubsample <$> nglConfiguration
    let subpostfix = if sub then ".subsampled" else ""
    ofile <- case lookup "ofile" args of
        Just (NGOFilename p) -> return (p ++ subpostfix)
        Just (NGOString p) -> return (T.unpack p ++ subpostfix)
        _ -> throwShouldNotOccur "getOFile cannot decode file path"
    format <- fmapMaybeM (symbolOrTypeError "format argument to write() function") (lookup "format" args)
    canMove <- lookupBoolOrScriptErrorDef (return False) "internal write arg" "__can_move" args
    verbose <- lookupBoolOrScriptErrorDef (return False) "write arg" "verbose" args
    comment <- fmapMaybeM (stringOrTypeError "comment argument to write() function") (lookup "comment" args)
    autoComments <- case lookup "auto_comments" args of
                        Nothing -> return []
                        Just (NGOList cs) -> mapM (\s -> do
                                                        let errmsg = "auto_comments argument in write() call"
                                                        symbolOrTypeError errmsg s >>=
                                                            decodeSymbolOrError errmsg
                                                                [("date", AutoDate)
                                                                ,("script", AutoScript)
                                                                ,("hash", AutoResultHash)]) cs
                        _ -> throwScriptError "auto_comments argument to write() call must be a list of symbols"
    hash <- lookupStringOrScriptError "hidden __hash argument to write() function" "__hash" args
    formatFlags <- case lookup "format_flags" args of
                        Nothing -> return Nothing
                        Just (NGOSymbol flag) -> return $ Just flag
                        Just other -> throwScriptError $ "format_flags argument to write(): illegal argument ("++show other++")"
    return $! WriteOptions
                { woOFile = ofile
                , woFormat = format
                , woFormatFlags = formatFlags
                , woCanMove = canMove
                , woVerbose = verbose
                , woComment = comment
                , woAutoComment = autoComments
                , woHash = hash
                }


moveOrCopyCompress :: Bool -> FilePath -> FilePath -> NGLessIO ()
moveOrCopyCompress _ orig "/dev/stdout" = C.runConduit $ conduitPossiblyCompressedFile orig .| C.stdout
moveOrCopyCompress canMove orig fname = moveOrCopyCompress' orig fname
    where
        moveOrCopyCompress' :: FilePath -> FilePath -> NGLessIO ()
        moveOrCopyCompress'
            | igz && ogz = moveIfCan
            | igz = uncompressTo
            | ogz = compressTo
            | otherwise = moveIfCan

        moveIfCan :: FilePath -> FilePath -> NGLessIO ()
        moveIfCan = if canMove
                       then liftIO2 moveOrCopy
                       else maybeCopyFile

        liftIO2 f a b = liftIO (f a b)
        isGZ = endswith ".gz"
        igz = isGZ orig
        ogz = isGZ fname
        uncompressTo oldfp newfp = C.runConduit $
            conduitPossiblyCompressedFile oldfp .| CB.sinkFileCautious newfp
        compressTo oldfp newfp = liftIO $
            withOutputFile' newfp $ \hout ->
                C.runConduitRes $
                    C.sourceFile oldfp .| asyncGzipTo hout

        -- | copy file unless its the same file.
        maybeCopyFile :: FilePath -> FilePath -> NGLessIO ()
        maybeCopyFile old new
            | new == old = return()
            | otherwise = liftIO (copyFile old new)

removeEnd :: String -> String -> String
removeEnd base suffix = take (length base - length suffix) base

_formatFQOname base insert
    | "{index}" `isInfixOf` base = return $ replace "{index}" insert base
    | endswith ".fq" base = return $ removeEnd base ".fq" ++ "." ++ insert ++ ".fq"
    | endswith ".fq.gz" base = return $ removeEnd base ".fq.gz" ++ "." ++ insert ++ ".fq.gz"
    | endswith ".fq.bz2" base = return $ removeEnd base ".fq.bz2" ++ "." ++ insert ++ ".fq.bz2"
    | otherwise = throwScriptError ("Cannot handle filename " ++ base ++ " (expected extension .fq/.fq.gz/.fq.bz2).")



executeWrite :: NGLessObject -> [(T.Text, NGLessObject)] -> NGLessIO NGLessObject
executeWrite (NGOList el) args = do
    templateFP <- woOFile <$> parseWriteOptions args
    let args' = filter (\(a,_) -> (a /= "ofile")) args
        fps = map ((\fname -> replace "{index}" fname templateFP) . show) [1..length el]
    zipWithM_ (\e fp -> executeWrite e (("ofile", NGOFilename fp):args')) el fps
    return NGOVoid

executeWrite (NGOReadSet _ rs) args = do
    opts <- parseWriteOptions args
    let ofile = woOFile opts
        moveOrCopyCompressFQs :: [FastQFilePath] -> FilePath -> NGLessIO ()
        moveOrCopyCompressFQs [] _ = return ()
        moveOrCopyCompressFQs [FastQFilePath _ f] ofname = moveOrCopyCompress (woCanMove opts) f ofname
        moveOrCopyCompressFQs multiple ofname = do
            let inputs = fqpathFilePath <$> multiple
            fp' <- makeNGLTempFile (head inputs) "concat" "tmp" $ \h ->
                C.runConduit
                    (mapM_ conduitPossiblyCompressedFile inputs .| C.sinkHandle h)
            moveOrCopyCompress True fp' ofname
    if woFormatFlags opts == Just "interleaved"
        then do
            writer <- if endswith ".gz" ofile
                        then return asyncGzipTo
                        else if endswith ".bz2" ofile
                            then
#ifndef WINDOWS
                                return (\hout -> CBZ2.bzip2 .| CB.sinkHandle hout)
#else
                                throwNotImplementedError "Compression of bzip2 files is not supported on Windows"
#endif

                            else return CB.sinkHandle
            withOutputFile' ofile $ \hout -> do
                let ReadSet pairs singles = rs
                C.runConduitRes $
                    interleaveFQs pairs singles .| writer hout
        else case rs of
            ReadSet [] singles ->
                moveOrCopyCompressFQs singles ofile
            ReadSet pairs [] -> do
                fname1 <- _formatFQOname ofile "pair.1"
                fname2 <- _formatFQOname ofile "pair.2"
                moveOrCopyCompressFQs (fst <$> pairs) fname1
                moveOrCopyCompressFQs (snd <$> pairs) fname2
            ReadSet pairs singletons -> do
                fname1 <- _formatFQOname ofile "pair.1"
                fname2 <- _formatFQOname ofile "pair.2"
                fname3 <- _formatFQOname ofile "singles"
                moveOrCopyCompressFQs (fst <$> pairs) fname1
                moveOrCopyCompressFQs (snd <$> pairs) fname2
                moveOrCopyCompressFQs singletons fname3
    return NGOVoid
executeWrite el@(NGOMappedReadSet _ iout  _) args = do
    opts <- parseWriteOptions args
    fp <- asFile iout
    let guessFormat :: String -> NGLessIO T.Text
        guessFormat "/dev/stdout" = return "sam"
        guessFormat ofile
            | endswith ".sam" ofile = return "sam"
            | endswith ".sam.gz" ofile = return "sam"
            | endswith ".sam.bz2" ofile = return "sam"
            | endswith ".bam" ofile = return "bam"
            | otherwise = do
                outputListLno' WarningOutput ["Cannot determine format of MappedReadSet output based on filename ('", ofile, "'). Defaulting to BAM."]
                return "bam"
    orig <- maybe (guessFormat (woOFile opts)) return (woFormat opts) >>= \case
        "sam"
            | endswith ".bam" fp -> convertBamToSam fp
            | otherwise -> return fp
        "bam"
            | endswith ".bam" fp -> return fp -- We already have a BAM, so just copy it
            | otherwise -> convertSamToBam fp
        s -> throwScriptError ("write does not accept format {" ++ T.unpack s ++ "} with input type " ++ show el)
    moveOrCopyCompress (woCanMove opts) orig (woOFile opts)
    return NGOVoid

executeWrite (NGOCounts iout) args = do
    opts <- parseWriteOptions args
    outputListLno' InfoOutput ["Writing counts to: ", woOFile opts]
    comment <- buildComment (woComment opts) (woAutoComment opts) (woHash opts)
    case fromMaybe "tsv" (woFormat opts) of
        "tsv" -> do
            fp <- asFile iout
            case comment of
                [] -> moveOrCopyCompress (woCanMove opts) fp (woOFile opts)
                _ -> C.runConduit $
                        (commentC "# " comment >> CB.sourceFile fp)
                        .| CB.sinkFileCautious (woOFile opts)
        "csv" -> do
            let (fp,istream) = asStream iout
            comma <- makeNGLTempFile fp "wcomma" "csv" $ \ohand ->
                C.runConduit $
                    ((commentC "# " comment .| linesVC 1024) >> istream)
                        .| CL.map (V.map tabToComma)
                        .| CC.concat
                        .| byteLineSinkHandle ohand
            moveOrCopyCompress True comma (woOFile opts)
        f -> throwScriptError ("Invalid format in write: {"++T.unpack f++"}.\n\tWhen writing counts, only accepted values are {tsv} (TAB separated values; default) or {csv} (COMMA separated values).")
    return NGOVoid
  where
    tabToComma :: ByteLine -> ByteLine
    tabToComma (ByteLine line) = ByteLine $ B8.map (\case { '\t' -> ','; c -> c }) line

executeWrite (NGOFilename fp) args = do
    opts <- parseWriteOptions args
    moveOrCopyCompress (woCanMove opts) fp (woOFile opts)
    return NGOVoid

executeWrite v _ = throwShouldNotOccur ("Error: executeWrite of " ++ show v ++ " not implemented yet.")


