{- Copyright 2013-2018 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE TemplateHaskell, RecordWildCards, CPP #-}

module Output
    ( OutputType(..)
    , MappingInfo(..)
    , AutoComment(..)
    , buildComment
    , commentC
    , outputListLno
    , outputListLno'
    , outputFQStatistics
    , outputMappedSetStatistics
    , writeOutputJSImages
    , writeOutputTSV
    , outputConfiguration
    ) where

import           Text.Printf (printf)
import           System.IO (hIsTerminalDevice, stdout)
import           System.IO.Unsafe (unsafePerformIO)
import           System.IO.SafeWrite (withOutputFile)
import           Data.Maybe (maybeToList, fromMaybe, isJust)
import           Data.IORef (IORef, newIORef, modifyIORef, readIORef)
import           Data.List (sort)
import           Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import           System.FilePath ((</>))
import           Data.Aeson.TH (deriveToJSON, defaultOptions, Options(..))
import           Data.Time (getZonedTime, ZonedTime(..))
import           Data.Time.Format (formatTime, defaultTimeLocale)
import qualified System.Console.ANSI as ANSI
import           Control.Monad
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Extra (whenJust)
import           Numeric (showFFloat)
import           Control.Arrow (first)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Conduit as C
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.ByteString.Lazy as BL
#ifdef HAS_CAIRO
import qualified Graphics.Rendering.Chart.Easy as G
import qualified Graphics.Rendering.Chart.Backend.Cairo as G
#endif
import           System.Environment (lookupEnv)


import           Data.FastQ (FastQEncoding(..), encodingName)
import qualified Data.FastQ as FQ
import Configuration
import CmdArgs (Verbosity(..))
import NGLess.NGLEnvironment
import NGLess.NGError

data AutoComment = AutoScript | AutoDate | AutoResultHash
                        deriving (Eq, Show)


buildComment :: Maybe T.Text -> [AutoComment] -> T.Text -> NGLessIO [T.Text]
buildComment c ac rh = do
        ac' <- mapM buildAutoComment ac
        return $ maybeToList c ++ concat ac'
    where
        buildAutoComment :: AutoComment -> NGLessIO [T.Text]
        buildAutoComment AutoDate = liftIO $ do
            t <- formatTime defaultTimeLocale "%a %d-%m-%Y %R" <$> getZonedTime
            return . (:[]) $ T.concat ["Script run on ", T.pack t]
        buildAutoComment AutoScript = (("Output generated by:":) . map addInitialIndent . T.lines . ngleScriptText) <$> nglEnvironment
        buildAutoComment AutoResultHash = return [T.concat ["Output hash: ", rh]]
        addInitialIndent t = T.concat ["    ", t]

commentC :: Monad m => B.ByteString -> [T.Text] -> C.ConduitT () B.ByteString m ()
commentC cmarker cs = forM_ cs $ \c -> do
                                C.yield cmarker
                                C.yield (TE.encodeUtf8 c)
                                C.yield "\n"


data OutputType = TraceOutput | DebugOutput | InfoOutput | ResultOutput | WarningOutput | ErrorOutput
    deriving (Eq, Ord)

instance Show OutputType where
    show TraceOutput = "trace"
    show DebugOutput = "debug"
    show InfoOutput = "info"
    show ResultOutput = "result"
    show WarningOutput = "warning"
    show ErrorOutput = "error"

data OutputLine = OutputLine !Int !OutputType !ZonedTime !String

instance Aeson.ToJSON OutputLine where
    toJSON (OutputLine lno ot t m) = Aeson.object
                                        ["lno" .= lno
                                        , "time" .=  formatTime defaultTimeLocale "%a %d-%m-%Y %T" t
                                        , "otype" .= show ot
                                        , "message" .= m
                                        ]


data BPosInfo = BPosInfo
                    { _mean :: !Int
                    , _median :: !Int
                    , _lowerQuartile :: !Int
                    , _upperQuartile :: !Int
                    } deriving (Show)
$(deriveToJSON defaultOptions{fieldLabelModifier = drop 1} ''BPosInfo)

data FQInfo = FQInfo
                { fileName :: String
                , scriptLno :: !Int
                , gcContent :: !Double
                , nonATCGFrac :: !Double
                , encoding :: !String
                , numSeqs :: !Int
                , numBasepairs :: !Integer
                , seqLength :: !(Int,Int)
                , perBaseQ :: [BPosInfo]
                } deriving (Show)

$(deriveToJSON defaultOptions ''FQInfo)

data MappingInfo = MappingInfo
                { mi_lno :: Int
                , mi_inputFile :: FilePath
                , mi_reference :: String
                , mi_totalReads :: !Int
                , mi_totalAligned :: !Int
                , mi_totalUnique :: !Int
                } deriving (Show)

$(deriveToJSON defaultOptions{fieldLabelModifier = drop 3} ''MappingInfo)

savedOutput :: IORef [OutputLine]
{-# NOINLINE savedOutput #-}
savedOutput = unsafePerformIO (newIORef [])

savedFQOutput :: IORef [FQInfo]
{-# NOINLINE savedFQOutput #-}
savedFQOutput = unsafePerformIO (newIORef [])

savedMapOutput :: IORef [MappingInfo]
{-# NOINLINE savedMapOutput #-}
savedMapOutput = unsafePerformIO (newIORef [])

-- | See `outputListLno'`, which is often the right function to use
outputListLno :: OutputType      -- ^ Level at which to output
                    -> Maybe Int -- ^ Line number (in script). Use 'Nothing' for global messages
                    -> [String]
                    -> NGLessIO ()
outputListLno ot lno ms = output ot (fromMaybe 0 lno) (concat ms)

-- | Output a message.
-- This function takes a list as it is often a more convenient interface
outputListLno' :: OutputType      -- ^ Level at which to output
                    -> [String]   -- ^ output. Will be 'concat' together (without any spaces or similar in between)
                    -> NGLessIO ()
outputListLno' !ot ms = do
    lno <- ngleLno <$> nglEnvironment
    outputListLno ot lno ms

shouldPrint :: Bool -- ^ is terminal
                -> OutputType
                -> Verbosity
                -> Bool
shouldPrint _ TraceOutput _ = False
shouldPrint _      _ Loud = True
shouldPrint False ot Quiet = ot == ErrorOutput
shouldPrint False ot Normal = ot > InfoOutput
shouldPrint True  ot Quiet = ot >= WarningOutput
shouldPrint True  ot Normal = ot >= InfoOutput

output :: OutputType -> Int -> String -> NGLessIO ()
output !ot !lno !msg = do
    isTerm <- liftIO $ hIsTerminalDevice stdout
    hasNOCOLOR <- isJust <$> liftIO (lookupEnv "NO_COLOR")
    verb <- nConfVerbosity <$> nglConfiguration
    traceSet <- nConfTrace <$> nglConfiguration
    colorOpt <- nConfColor <$> nglConfiguration
    let sp = traceSet || shouldPrint isTerm ot verb
        doColor = case colorOpt of
            ForceColor -> True
            NoColor -> False
            AutoColor -> isTerm && not hasNOCOLOR
    c <- colorFor ot
    liftIO $ do
        t <- getZonedTime
        modifyIORef savedOutput (OutputLine lno ot t msg:)
        when sp $ do
            let st = if doColor
                        then ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Dull c]
                        else ""
                rst = if doColor
                        then ANSI.setSGRCode [ANSI.Reset]
                        else ""
                tformat = if traceSet -- when trace is set, output seconds
                                then "%a %d-%m-%Y %T"
                                else "%a %d-%m-%Y %R"
                tstr = formatTime defaultTimeLocale tformat t
                lineStr = if lno > 0
                                then printf " Line %s" (show lno)
                                else "" :: String
            putStrLn $ printf "%s[%s]%s: %s%s" st tstr lineStr msg rst

colorFor :: OutputType -> NGLessIO ANSI.Color
colorFor = return . colorFor'
    where
        colorFor' TraceOutput   = ANSI.White
        colorFor' DebugOutput   = ANSI.White
        colorFor' InfoOutput    = ANSI.Blue
        colorFor' ResultOutput  = ANSI.Black
        colorFor' WarningOutput = ANSI.Yellow
        colorFor' ErrorOutput   = ANSI.Red


encodeBPStats :: FQ.FQStatistics -> [BPosInfo]
encodeBPStats res = map encode1 (FQ.qualityPercentiles res)
    where encode1 (mean, median, lq, uq) = BPosInfo mean median lq uq

outputFQStatistics :: FilePath -> FQ.FQStatistics -> FastQEncoding -> NGLessIO ()
outputFQStatistics fname stats enc = do
    lno' <- ngleLno <$> nglEnvironment
    let enc'    = encodingName enc
        sSize'  = FQ.seqSize stats
        nSeq'   = FQ.nSeq stats
        gc'     = FQ.gcFraction stats
        nATGC   = FQ.nonATCGFrac stats
        st      = encodeBPStats stats
        lno     = fromMaybe 0 lno'
        nbps    = FQ.nBasepairs stats
        binfo   = FQInfo fname lno gc' nATGC enc' nSeq' nbps sSize' st
    let p s0 s1  = outputListLno' DebugOutput [s0, s1]
    p "Simple Statistics completed for: " fname
    p "Number of base pairs: "      (show $ length (FQ.qualCounts stats))
    p "Encoding is: "               (show enc)
    p "Number of sequences: "   (show $ FQ.nSeq stats)
    liftIO $ modifyIORef savedFQOutput (binfo:)

outputMappedSetStatistics :: MappingInfo -> NGLessIO ()
outputMappedSetStatistics mi@(MappingInfo _ _ ref total aligned unique) = do
        lno <- ngleLno <$> nglEnvironment
        let out = outputListLno' ResultOutput
        out ["Mapped readset stats (", ref, "):"]
        out ["Total reads: ", show total]
        out ["Total reads aligned: ", showNumAndPercentage aligned]
        out ["Total reads Unique map: ", showNumAndPercentage unique]
        out ["Total reads Non-Unique map: ", showNumAndPercentage (aligned - unique)]
        liftIO $ modifyIORef savedMapOutput (mi { mi_lno = fromMaybe 0 lno }:)
    where
        showNumAndPercentage :: Int -> String
        showNumAndPercentage v = concat [show v, " [", showFFloat (Just 2) ((fromIntegral (100*v) / fromIntegral total') :: Double) "", "%]"]
        total' = if total /= 0 then total else 1


data InfoLink = HasQCInfo !Int
                | HasStatsInfo !Int
    deriving (Eq, Show)
instance Aeson.ToJSON InfoLink where
    toJSON (HasQCInfo lno) = Aeson.object
                                [ "info_type" .= ("has_QCInfo" :: String)
                                , "lno" .= show lno
                                ]
    toJSON (HasStatsInfo lno) = Aeson.object
                                [ "info_type" .= ("has_StatsInfo" :: String)
                                , "lno" .= show lno
                                ]

data ScriptInfo = ScriptInfo String String [(Maybe InfoLink,T.Text)] deriving (Show, Eq)
instance Aeson.ToJSON ScriptInfo where
   toJSON (ScriptInfo a b c) = Aeson.object [ "name" .= a,
                                            "time" .= b,
                                            "script" .= Aeson.toJSON c ]

wrapScript :: [(Int, T.Text)] -> [FQInfo] -> [Int] -> [(Maybe InfoLink, T.Text)]
wrapScript script tags stats = first annotate <$> script
    where
        annotate i
            | i `elem` (scriptLno <$> tags) = Just (HasQCInfo i)
            | i `elem` stats = Just (HasStatsInfo i)
            | otherwise =  Nothing

writeOutputJSImages :: FilePath -> FilePath -> T.Text -> IO ()
writeOutputJSImages odir scriptName script = do
    fullOutput <- reverse <$> readIORef savedOutput
    fqStats <- reverse <$> readIORef savedFQOutput
    mapStats <- reverse <$> readIORef savedMapOutput
    fqfiles <- forM (zip [(0::Int)..] fqStats) $ \(ix, q) -> do
        let oname = "output"++show ix++".png"
            bpos = perBaseQ q
        drawBaseQs (odir </> oname) bpos
        return oname
    t <- getZonedTime
    let script' = zip [1..] (T.lines script)
        sInfo = ScriptInfo (odir </> "output.js") (show t) (wrapScript script' fqStats (mi_lno <$> mapStats))
    withOutputFile (odir </> "output.js") $ \hout ->
        BL.hPutStr hout (BL.concat
                    ["var output = "
                    , Aeson.encode $ Aeson.object
                        [ "output" .= fullOutput
                        , "processed" .= sInfo
                        , "fqStats" .= fqStats
                        , "mapStats" .= mapStats
                        , "scriptName" .= scriptName
                        , "plots" .= fqfiles
                        ]
                    ,";\n"])


writeOutputTSV :: Bool -- ^ whether to transpose matrix
                -> Maybe FilePath
                -> Maybe FilePath
                -> IO ()
writeOutputTSV transpose fqStatsFp mapStatsFp = do
        fqStats <- reverse <$> readIORef savedFQOutput
        mapStats <- reverse <$> readIORef savedMapOutput
        whenJust fqStatsFp $ \fp ->
            withOutputFile fp $ \hout ->
                BL.hPut hout  . formatTSV $ encodeFQStats <$> fqStats
        whenJust mapStatsFp $ \fp ->
            withOutputFile fp $ \hout ->
                BL.hPutStr hout . formatTSV $ encodeMapStats <$> mapStats
    where
        formatTSV :: [[(BL.ByteString, String)]] -> BL.ByteString
        formatTSV [] = BL.empty
        formatTSV contents@(h:_)
            | transpose = BL.concat ("\tstats\n":(formatTSV1 <$> zip [0..] contents))
            | otherwise = BL.concat [BL8.intercalate "\t" (fst <$> h), "\n",
                                    BL8.intercalate "\n" (asTSVline . fmap snd <$> contents), "\n"]
        formatTSV1 :: (Int, [(BL.ByteString, String)]) -> BL.ByteString
        formatTSV1 (i, contents) = BL.concat [BL8.concat [BL8.concat [BL8.pack . show $ i, ":", h], "\t", BL8.pack c, "\n"]
                                                                        | (h, c) <- contents]
        asTSVline = BL8.intercalate "\t" . map BL8.pack

        encodeFQStats FQInfo{..} = sort
                            [ ("file", fileName)
                            , ("encoding", encoding)
                            , ("numSeqs", show numSeqs)
                            , ("numBasepairs", show numBasepairs)
                            , ("minSeqLen", show (fst seqLength))
                            , ("maxSeqLen", show (snd seqLength))
                            , ("gcContent", show gcContent)
                            , ("nonATCGFraction", show nonATCGFrac)
                            ]
        encodeMapStats MappingInfo{..} = sort
                [ ("inputFile", mi_inputFile)
                , ("lineNumber", show mi_lno)
                , ("reference", mi_reference)
                , ("total", show mi_totalReads)
                , ("aligned", show mi_totalAligned)
                , ("unique", show mi_totalUnique)
                ]

outputConfiguration :: NGLessIO ()
outputConfiguration = do
    cfg <- ngleConfiguration <$> nglEnvironment
    outputListLno' DebugOutput ["# Configuration"]
    outputListLno' DebugOutput ["\tdownload base URL: ", nConfDownloadBaseURL cfg]
    outputListLno' DebugOutput ["\tglobal data directory: ", nConfGlobalDataDirectory cfg]
    outputListLno' DebugOutput ["\tuser directory: ", nConfUserDirectory cfg]
    outputListLno' DebugOutput ["\tuser data directory: ", nConfUserDataDirectory cfg]
    outputListLno' DebugOutput ["\ttemporary directory: ", nConfTemporaryDirectory cfg]
    outputListLno' DebugOutput ["\tkeep temporary files: ", show $ nConfKeepTemporaryFiles cfg]
    outputListLno' DebugOutput ["\tcreate report: ", show $ nConfCreateReportDirectory cfg]
    outputListLno' DebugOutput ["\treport directory: ", nConfReportDirectory cfg]
    outputListLno' DebugOutput ["\tcolor setting: ", show $ nConfColor cfg]
    outputListLno' DebugOutput ["\tprint header: ",  show $ nConfPrintHeader cfg]
    outputListLno' DebugOutput ["\tsubsample: ", show $ nConfSubsample cfg]
    outputListLno' DebugOutput ["\tverbosity: ", show $ nConfVerbosity cfg]
    forM_ (nConfIndexStorePath cfg) $ \p ->
        outputListLno' DebugOutput ["\tindex storage path: ", p]
    outputListLno' DebugOutput ["\tsearch path:"]
    forM_ (nConfSearchPath cfg) $ \p ->
        outputListLno' DebugOutput ["\t\t", p]

drawBaseQs :: FilePath -> [BPosInfo] -> IO ()
#ifdef HAS_CAIRO
drawBaseQs oname bpos = G.toFile G.def oname $ do
    G.layout_title G..= "FastQ Quality Statistics"
    G.plot (G.line "Mean" [
                    [(ix, _mean bp) | (ix,bp) <- zip [1:: Integer ..] bpos]])
    G.plot (G.line "Median" [
                    [(ix, _median bp) | (ix,bp) <- zip [1:: Integer ..] bpos]])
    G.plot (G.line "Upper Quartile" [
                    [(ix, _upperQuartile bp) | (ix,bp) <- zip [1:: Integer ..] bpos]])
    G.plot (G.line "Lower Quartile" [
                    [(ix, _lowerQuartile bp) | (ix,bp) <- zip [1:: Integer ..] bpos]])

#else
drawBaseQs _ _ = return ()
#endif
