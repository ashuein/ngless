{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}
module Tests.Select
    ( tgroup_Select
    ) where

import Test.Framework.TH
import Test.HUnit
import Test.Framework.Providers.HUnit
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Builder as BB

import Interpretation.Select (_fixCigar)
import Data.Sam
import Tests.Utils
import Utils.Here


tgroup_Select = $(testGroupGenerator)


samLineFlat = [here|IRIS:7:3:1046:1723#0	4	*	0	0	40M	*	0	0	AAAAAAAAAAAAAAAAAAAATTTAAA	aaaaaaaaaaaaaaaaaa`abbba`^	AS:i:0	XS:i:0	NM:i:1|]
samLine = SamLine
            { samQName = "IRIS:7:3:1046:1723#0"
            , samFlag = 4
            , samRName = "*"
            , samPos = 0
            , samMapq = 0
            , samCigar = "40M"
            , samRNext = "*"
            , samPNext = 0
            , samTLen = 0
            , samSeq = "AAAAAAAAAAAAAAAAAAAATTTAAA"
            , samQual = "aaaaaaaaaaaaaaaaaa`abbba`^"
            , samExtra = "AS:i:0\tXS:i:0\tNM:i:1"
            }
simple = [here|
simulated:1:1:38:663#0	0	Ref1	1018	3	69M16S	=	1018	0	TTCGAGAAGATGGGTATCGTGGGAAATAACGGAACGGGGAAGTCTACCTTCATCAAGATGCTGCTGGGCTTGGTGAAACCCGACA	IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII	NM:i:5	MD:Z:17T5T14A2A2G24	AS:i:44	XS:i:40|]

complex = [here|
SRR070372.3	16	V	7198336	21	26M3D9M3D6M6D8M2D21M	*	0	0	CCCTTATGCAGGTCTTAACACAATTCTTGTATGTTCCATCGTTCTCCAGAATGAATATCAATGATACCAA	014<<BBBBDDFFFDDDDFHHFFD?@??DBBBB5555::?=BBBBDDF@BBFHHHHHHHFFFFFD@@@@@	NM:i:14	MD:Z:26^TTT9^TTC6^TTTTTT8^AA21	AS:i:3	XS:i:0|]

case_read_one_Sam_Line = readSamLine samLineFlat @?= Right samLine
case_encode = (BL.toStrict . BB.toLazyByteString . encodeSamLine $ samLine) @?= samLineFlat

case_isAligned_raw = isAligned (fromRight . readSamLine $ complex) @? "Should be aligned"
case_match_identity_soft = fromRight (matchIdentity samLine) == 0.975 @? "Soft clipped read (low identity)"

case_matchSize1 = fromRight (matchSize =<< readSamLine complex) @?= (26+  9+  6+  8+  21)
                                                                   --26M3D9M3D6M6D8M2D21M
case_matchSize2 = fromRight (matchSize =<< readSamLine simple) @?= 69

case_cigarOK = _fixCigar "9M" 9 @?= Right "9M"
case_cigarH = _fixCigar "4H5M" 9 @?= Right "4S5M"
