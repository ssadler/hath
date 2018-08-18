{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.ByteString.Lazy.Char8 as C8L

import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map as Map

import           Options.Applicative

import           Network.Ethereum.Contracts
import           Network.Ethereum.Crypto
import           Network.Ethereum.Data.RLP
import           Network.Ethereum.Transaction

import           Hath.Notariser.ETHKMD
import           Hath.Mandate.Agree
import           Hath.Data.Aeson hiding (Parser)
import           Hath.Monad
import           Hath.Prelude
import qualified Network.Haskoin.Internals as H

import           Language.Evm (codegen)

import           System.Exit
import           System.IO


main :: IO ()
main = join $ customExecParser (prefs showHelpOnEmpty) parseAct

type Method = IO ()

parseAct :: ParserInfo Method
parseAct = infoH topMethods $ fullDesc <> progDesc "Blockchain command line utils"
  where
    infoH m = info $ m <**> helper

    topMethods = subparser $
           (command "tx"       $ infoH txMethods         $ progDesc "Tx methods")
        <> (command "keyPair"  $ infoH keyPairMethod     $ progDesc "Generate a priv/pub key pair")
        <> (command "contract" $ infoH contractMethods   $ progDesc "Generate contracts")
        <> (command "notarise" $ infoH notariserMethods  $ progDesc "Notariser modes")

    txMethods = subparser $
           (command "encode"    $ infoH encodeTxMethod    $ progDesc "Encode a json transaction")
        <> (command "sign"      $ infoH signTxMethod      $ progDesc "Sign a transaction on stdin")
        <> (command "decode"    $ infoH decodeTxMethod    $ progDesc "Decode a transaction on stdin")
        <> (command "from"      $ infoH recoverFromMethod $ progDesc "Recover address")
        <> (command "txid"      $ infoH txidMethod        $ progDesc "Get transaction id")

    contractMethods = subparser $
           (command "contractProxy" $ infoH contractProxyMethod $ progDesc "Get code for proxy contract")

    notariserMethods = subparser $
           (command "ethkmd" $ infoH runEthNotariserMethod  $ progDesc "Run ETH -> KMD notariser")
        <> (command "seed"   $ infoH runSeedNotariserMethod $ progDesc "Run notariser seed node")


jsonMethod :: IO Value -> Method
jsonMethod act = act >>= C8L.putStrLn . encode


jsonArg :: FromJSON a => ReadM a
jsonArg = eitherReader $ eitherDecode . fromString


encodeTxMethod :: Parser Method
encodeTxMethod =
  let act = BS8.putStrLn . toHex . encodeTx
   in act <$> argument jsonArg (metavar "JSON TX")


signTxMethod :: Parser Method
signTxMethod = act <$> argument skArg (metavar "secret key")
  where skArg = maybeReader $ secKey . fst . B16.decode . fromString
        act sk = do
          (txBin,_) <- B16.decode <$> BS8.getContents
          let tx = rlpDecode $ rlpDeserialize txBin
              signed = signTx tx sk
          BS8.putStrLn $ toHex $ encodeTx signed


decodeTxMethod :: Parser Method
decodeTxMethod = pure $ jsonMethod $ do
  (txBin,_) <- B16.decode <$> BS8.getContents
  let tx = rlpDecode $ rlpDeserialize txBin :: Transaction
  pure $ toJSON tx


recoverFromMethod :: Parser Method
recoverFromMethod = pure $ jsonMethod $ do
  (txBin,_) <- B16.decode <$> BS8.getContents
  let tx = rlpDecode $ rlpDeserialize txBin :: Transaction
      toObj pk = object [ "pub" .= toJsonHex (BS.drop 1 (exportPubKey False pk))
                        , "addr" .= pubKeyAddr pk
                        ]
  maybe (fail "Invalid recovery data") (pure . toObj) $ recoverFrom tx


txidMethod :: Parser Method
txidMethod = pure $ do
  (txBin,_) <- B16.decode <$> BS8.getContents
  let tx = rlpDecode $ rlpDeserialize txBin :: Transaction
  BS8.putStrLn $ toHex $ unSha3 $ txid tx


keyPairMethod :: Parser Method
keyPairMethod = pure $ jsonMethod $ do
  sk <- genSecKey
  let pk = derivePubKey sk
  return $ object [ "secKey" .= show sk
                  , "pubKey" .= show pk
                  , "addr" .= pubKeyAddr pk
                  ]


contractProxyMethod :: Parser Method
contractProxyMethod = act <$> optInit <*> argAddress
  where act doInit addr =
          let code = if doInit then initEvmContract $ contractProxy addr
                               else contractProxyCode addr
           in putStrLn code
        argAddress = argument auto (metavar "target contract address")
        optInit = switch $ long "init" <> short 'i' <> help "Return code for contract init"


runEthNotariserMethod :: Parser Method
runEthNotariserMethod =
  runEthNotariser <$> optional optAddress <*> optConfig
  where
    optAddress = option auto
                 ( short 'm'
                <> long "mandate"
                <> help "Mandate contract address 0x..." )
    optConfig = strOption
                ( short 'c'
               <> long "config"
               <> help "Path to hath.json"
               <> value "~/.hath/hath.json"
               <> showDefault )

runSeedNotariserMethod :: Parser Method
runSeedNotariserMethod = pure runSeed
