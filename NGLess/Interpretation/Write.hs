{-# LANGUAGE OverloadedStrings #-}

module Interpretation.Write
    ( writeToFile
    ) where


import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import qualified Data.Map as M
import System.Directory (canonicalizePath)
import System.Process
import System.Exit
import System.IO
import Data.Maybe

import Language
import FileManagement
import JSONManager
import Configuration
import Data.AnnotRes

getNGOString (Just (NGOString s)) = s
getNGOString _ = error "Error: Type is different of String"

writeToUncFile (NGOMappedReadSet path defGen) newfp = do
    let path' = B.pack . T.unpack $ path
    readPossiblyCompressedFile (B.unpack path') >>= BL.writeFile (T.unpack newfp)
    return $ NGOMappedReadSet newfp defGen

writeToUncFile (NGOReadSet path enc tmplate) newfp = do
    let newfp' = T.unpack newfp
    readPossiblyCompressedFile path >>= BL.writeFile newfp'
    return $ NGOReadSet newfp' enc tmplate

writeToUncFile obj _ = error ("writeToUncFile: Should have received a NGOReadSet or a NGOMappedReadSet but the type was: " ++ (show obj))


writeToFile :: NGLessObject -> [(T.Text, NGLessObject)] -> IO NGLessObject
writeToFile (NGOList el) args = do
      let templateFP = getNGOString $ lookup "ofile" args
          newFPS' = map (\x -> T.replace "{index}" x templateFP) indexFPs
      res <- zipWithM (\x fp -> writeToFile x (fp' fp)) el newFPS'
      return (NGOList res)
    where
        indexFPs = map (T.pack . show) [1..(length el)]
        fp' fp = M.toList $ M.insert "ofile" (NGOString fp) (M.fromList args)

writeToFile el@(NGOReadSet _ _ _) args = writeToUncFile el $ getNGOString ( lookup "ofile" args )
writeToFile el@(NGOMappedReadSet fp defGen) args = do
    let newfp = getNGOString (lookup (T.pack "ofile") args) --
        format = fromMaybe (NGOSymbol "sam") (lookup "format" args)
    case format of
        (NGOSymbol "sam") -> writeToUncFile el newfp
        (NGOSymbol "bam") -> do
                        newfp' <- convertSamToBam (T.unpack fp) (T.unpack newfp)
                        return (NGOMappedReadSet newfp' defGen) --newfp will contain the bam
        _ -> error "This format should have been impossible"
writeToFile (NGOAnnotatedSet fp) args = do
    let newfp = getNGOString $ lookup "ofile" args
        del = getDelimiter  $ lookup "format" args
    printNglessLn $ "Writing your NGOAnnotatedSet to: " ++ (T.unpack newfp)
    cont <- readPossiblyCompressedFile (T.unpack fp)
    case lookup "verbose" args of
        Just (NGOSymbol "no")  -> writeAnnotResWDel' newfp $ showUniqIdCounts del cont
        Just (NGOSymbol "yes") -> writeAnnotResWDel' newfp (showGffCountDel del . readAnnotCounts $ cont)
        Just err -> error ("verbose received a " ++ (show err) ++ " but value can only be yes or no.")
        Nothing -> writeAnnotResWDel' newfp $ showUniqIdCounts del cont
    where
        writeAnnotResWDel' p cont = do
            BL.writeFile (T.unpack p) cont
            canonicalizePath (T.unpack p) >>= insertCountsProcessedJson
            return $ NGOAnnotatedSet p
writeToFile _ _ = error "Error: writeToFile Not implemented yet"

getDelimiter :: Maybe NGLessObject -> B.ByteString
getDelimiter x = case x of
        (Just (NGOSymbol "csv")) -> ","
        (Just (NGOSymbol "tsv")) -> "\t"
        (Just err) ->  error ("Type must be NGOSymbol, but was given" ++ (show err))
        Nothing -> "\t"

convertSamToBam samfile newfp = do
    printNglessLn $ "Start to convert Sam to Bam. from " ++ samfile ++ " to -> " ++ newfp
    samPath <- samtoolsBin
    withFile newfp WriteMode $ \hout -> do
        (_, _, Just herr, jHandle) <- createProcess (
            proc samPath
                ["view", "-bS", samfile]
            ){ std_out = UseHandle hout,
               std_err = CreatePipe }
        hGetContents herr >>= putStrLn
        exitCode <- waitForProcess jHandle
        case exitCode of
           ExitSuccess -> return (T.pack newfp)
           ExitFailure err -> error ("Failure on converting sam to bam" ++ (show err))