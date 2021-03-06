{-# LANGUAGE OverloadedStrings #-}

module TestProof where

import           Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

import           Hath.Prelude
import           Hath.Notariser.ETHProof
import           Network.Ethereum
import           Network.Komodo

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.QuickCheck.Instances
import           Test.Tasty.QuickCheck hiding (Fixed)


proofTests :: TestTree
proofTests = testGroup "receipt proofs"
  [ proof_100004
  , proof_100013
  , encodeReceipts
  , testCmpNotarisationRange
  ]


proof_100004 :: TestTree
proof_100004 = testCase "100004" $ do

  let Just receipt_c0e5 = Data.Aeson.decode "{ \
  \  \"contractAddress\": null, \
  \  \"logsBloom\": \"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\", \
  \  \"status\": null, \
  \  \"gasUsed\": \"0x5208\", \
  \  \"blockHash\": \"0xf93283571ae16dcecbe1816adc126954a739350cd1523a1559eabeae155fbb63\", \
  \  \"transactionHash\": \"0x6f12399cc2cb42bed5b267899b08a847552e8c42a64f5eb128c1bcbd1974fb0c\", \
  \  \"root\": \"0x010cff99b483514b78eafcee3af606b4ec521db5a3012075e6ba7e2704ff6549\", \
  \  \"cumulativeGasUsed\": \"0x5208\", \
  \  \"logs\": [], \
  \  \"blockNumber\": \"0x186a4\", \
  \  \"transactionIndex\": \"0x0\" \
  \ }" :: Maybe TransactionReceipt

  let receiptsRoot = "0xc0e5c4416c69d9c286d3f541ee22f79ad47d27d8b7b3389ff986a021bee2b2f9"
  trieRoot (calcReceiptsRoot [receipt_c0e5]) @?= receiptsRoot



proof_100013 = testCase "100013" $ do
  let receiptsRoot = "0x1b26dff83652d5e430c7e459fd8cfa61936ce9afbe4e3e65c185fd9ce0944a6c"
  Just receipts <- decode <$> BSL.readFile "test/assets/block_100013_receipts.json"
  trieRoot (calcReceiptsRoot receipts) @?= receiptsRoot


calcReceiptsRoot :: [TransactionReceipt] -> Trie
calcReceiptsRoot receipts = orderedTrie $ rlpSerialize . rlpEncode <$> receipts


encodeReceipts = testGroup "encodeReceipts"
  [ testCase "50010.0" $ do
      let receipt =
            Receipt { blockHash = "9b39a465d46cfcb352ea76e95037826dae53cb0d5e69098d1f55056e83eaadc4"
                      , transactionIndex = 0
                      , gasUsed = 21612
                      , cumulativeGasUsed = 21612
                      , root = Just "dc6ad90d17590c3c9eb38ce3960784237d98e0b8319a0bcff3a9cb873fb0b8ef"
                      , status = Nothing
                      , logsBloom = Hex $ BS.replicate (256::Int) 0
                      , logs = []
                   }

      toHex (rlpSerialize (rlpEncode receipt)) @?= "f90128a0dc6ad90d17590c3c9eb38ce3960784237d98e0b8319a0bcff3a9cb873fb0b8ef82546cb9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0"

  , testCase "50010.1" $ do
      let receipt2 =
            Receipt { blockHash = "9b39a465d46cfcb352ea76e95037826dae53cb0d5e69098d1f55056e83eaadc4"
                      , transactionIndex = 1
                      , gasUsed = 21612
                      , cumulativeGasUsed = 43224  -- Accumulated gas!
                      , root = Just "9c9046f595534d3d519d9d5021e39bfe1d9182dbdfd09ee7e50593036248cb64"
                      , status = Nothing
                      , logsBloom = Hex $ BS.replicate (256::Int) 0
                      , logs = []
                   }
      toHex (rlpSerialize (rlpEncode receipt2)) @?= "f90128a09c9046f595534d3d519d9d5021e39bfe1d9182dbdfd09ee7e50593036248cb6482a8d8b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0"
  ]


testCmpNotarisationRange = testGroup "cmpNotarisationRange"
  [ testCase "ranges" $ do
      let mockData = NOR () 100 "" () 2 0
      cmpNotarisationRange mockData <$> [98..101] @?= [LT,EQ,EQ,GT]
  , testCase "0depth" $ do
      let mockData = NOR () 100 "" () 0 0
      cmpNotarisationRange mockData <$> [100,101] @?= [LT,GT]
  ]
