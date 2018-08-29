{-# LANGUAGE DeriveGeneric #-}

module Hath.Notariser.ETHKMD where

import qualified Data.Serialize as Ser

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Exception.Safe (catchAny)
import           Control.Monad (forever)

import qualified Data.ByteString as BS
import qualified Data.Map as Map
import           Data.Scientific
import           Data.Typeable

import           GHC.Generics

import           Network.HTTP.Simple
import           Network.Ethereum.Crypto
import           Network.Ethereum.Data
import           Network.Ethereum.RPC
import           Network.Bitcoin
import qualified Network.Haskoin.Internals as H
import           Network.Komodo

import           Hath.Config
import           Hath.Concurrent
import           Hath.Data.Aeson
import           Hath.Data.Binary
import           Hath.Consensus
import           Hath.Notariser.UTXOs
import           Hath.Mandate
import           Hath.Monad
import           Hath.Prelude
import Debug.Trace


kmdInputAmount :: Word64
kmdInputAmount = 9800

consensusTimeout :: Int
consensusTimeout = 10 * 1000000

data ChainConf = CConf
  { chainCCId :: Word16
  , chainSymbol :: String
  , chainNotarySigs :: Int
  , chainNotaries :: [Address]
  } deriving (Generic, Show)

instance FromJSON ChainConf
instance ToJSON ChainConf

data ConfigException = ConfigException
  deriving (Show)
instance Exception ConfigException

data EthNotariser = EthNotariser
  { getKomodoConfig :: BitcoinConfig
  , getNode :: ConsensusNode
  , gethConfig :: GethConfig
  , getMandateAddr :: Address
  , getSecret :: SecKey
  }

instance Has GethConfig    EthNotariser where has = gethConfig
instance Has BitcoinConfig EthNotariser where has = getKomodoConfig
instance Has ConsensusNode EthNotariser where has = getNode


-- Entry point for ETH notariser program
--
runEthNotariser :: GethConfig -> ConsensusNetworkConfig -> Address -> H.Address -> IO ()
runEthNotariser gethConfig consensusConfig mandateAddr kmdAddr = do
  threadDelay 2000000
  initKomodo
  runHath () $ do
    bitcoinConf <- loadBitcoinConfig "~/.komodo/komodo.conf"

    -- resolve pk
    wif <- hathReader (const bitcoinConf) $ queryBitcoin "dumpprivkey" [kmdAddr]
    let sk = H.prvKeySecKey $ (fromString wif :: H.PrvKey)

    node <- liftIO $ spawnConsensusNode consensusConfig
    let config = EthNotariser bitcoinConf node gethConfig mandateAddr sk
    hathReader (const config) ethNotariser


-- Run configured notariser
--
ethNotariser :: Hath EthNotariser ()
ethNotariser = do
  ident@(wif, pk, myAddr) <- getBitcoinIdent
  logInfo $ "My bitcoin addr: " ++ show myAddr
  monitorUTXOs kmdInputAmount 5 ident

  run $ do
    chainConf <- getMandateInfos

    getEthIdent >>= checkConfig chainConf

    mutxo <- chooseUtxo <$> bitcoinUtxos [myAddr]
    case mutxo of
         Nothing -> do
           logInfo "Waiting for UTXOs"
           liftIO $ threadDelay $ 60 * 1000000
         Just utxo -> do
           range <- getBlockRange chainConf
           logDebug $ "Got block range: " ++ show range
           blocks <- getBlocksInRange range
           if null blocks
              then do
                logInfo $ "Waiting for more blocks to notarise: " ++ show range
                liftIO $ threadDelay $ 60 * 1000000
              else do
                logInfo $ "Notarising range: " ++ show range
                let ndata = getNotarisationData chainConf blocks
                runNotariserConsensus utxo ndata chainConf

                -- Consistency check
                mln <- getLastNotarisation $ chainSymbol chainConf
                when (mln /= Just ndata) $ do
                   logError ("Bad error. Notarisation tx confirmed but " ++
                             "didn't show up in db.")
                   logError $ show (range, ndata, mln)
                   error "Bailing"
  where
    run act = do
      r <- ask
      _ <- liftIO $ forever $ runHath r act `catches` handlers
      pure ()
    handlers =
      [ Handler $ \e -> recover logInfo 5 (e :: ConsensusException)
      , Handler $ \e -> recover logWarn 60 (e :: HttpException)
      , Handler $ \e -> recover logError 600 (e :: ConfigException)
      ]
    recover f d e = do
      runHath () $ f $ show e
      threadDelay $ d * 1000000

    checkConfig CConf{..} (_, addr) = do
      when (majorityThreshold (length chainNotaries) < chainNotarySigs) $ do
        logError "Majority threshold is less than required notary sigs"
        impureThrow ConfigException 
      when (not $ elem addr chainNotaries) $ do
        logError "I am not in the members list 😢 "
        impureThrow ConfigException

-- Run consensus if UTXO and block limits are available
--
runNotariserConsensus :: BitcoinUtxo -> NotarisationData Sha3
                      -> ChainConf -> Hath EthNotariser ()
runNotariserConsensus utxo ndata cconf@CConf{..} = do
  (wif, pk, kmdAddr) <- getBitcoinIdent
  ident <- getEthIdent
  let cparams = ConsensusParams chainNotaries ident consensusTimeout
  r <- ask
  let run = liftIO . runHath r
  let opret = Ser.encode ndata

  runConsensus cparams opret $ do
    {- The trick is, that during this whole block inside runConsensus,
       each step will stay open until the end so that lagging nodes can
       join in late. Latecomers have no effect on the outcome. -}

    -- Step 1 - Key on opret, collect UTXOs
    run $ logDebug "Step 1: Collect inputs"
    utxoBallots <- step waitMajority (pk, getOutPoint utxo)

    -- Step 2 - TODO: Key on proposer
    run $ logDebug "Step 2: Get proposed inputs"
    utxosChosen <- propose $ pure $ proposeInputs cconf utxoBallots

    -- Step 3 - Sign tx and collect signed inputs
    run $ logDebug "Step 3: Sign & collect"
    let signedTx = signMyInput wif utxosChosen $ H.DataCarrier opret
        myInput = getMyInput utxo signedTx
        waitSigs = waitOutpoints $ snd <$> utxosChosen
    allSignedInputs <- step waitSigs myInput
    let finalTx = compileFinalTx signedTx allSignedInputs

    -- Step 4 - Confirm step 3 (bad attempt to overcome two general's problem)
    run $ logDebug "Step 4: Just for kicks"
    _ <- step waitMajority ()

    run $ do
      logInfo $ "Broadcast transaction: " ++ show (H.txHash finalTx)
      bitcoinSubmitTxSync finalTx
      logInfo $ "Transaction confirmed"
      liftIO $ threadDelay $ 10 * 1000000

getMandateInfos :: Hath EthNotariser ChainConf
getMandateInfos = do
  addr <- asks getMandateAddr
  (val, members, _) <- mandateGetData addr
  let chainConf = val .! "{ETHKMD}"
  pure chainConf { chainNotaries = members }

getBlocksInRange :: (U256, U256) -> Hath EthNotariser [EthBlock]
getBlocksInRange (from, to) = do
  logTime ("eth_getBlockByNumber: " ++ show (from, to)) $ do
    parM 10 [from..to] $ \n -> do
        eth_getBlockByNumber n

getBlockRange :: ChainConf -> Hath EthNotariser (U256, U256)
getBlockRange CConf{..} = do
  mlastNota <- getLastNotarisation chainSymbol
  end <- getEthProposeHeight 10
  case mlastNota of
       Nothing -> do
         logInfo $ "No prior notarisations found"
         pure (end, end)
       Just (NOR{..}) -> do
         let start = fromIntegral blockNumber + 1
         let noop = blockHash :: Sha3 -- clue in type system
         pure (start, min end (start+999))

getEthProposeHeight :: Has GethConfig r => U256 -> Hath r U256
getEthProposeHeight n = do
  height <- eth_blockNumber
  pure $ height - mod height n

waitOutpoints :: [H.OutPoint] -> Waiter (Maybe H.TxIn)
waitOutpoints given = waitGeneric test
  where test _ inv =
          let getOPs = map H.prevOutput . catMaybes . map snd
              vals = getOPs $ Map.elems inv
           in sortOn show vals == sortOn show given

-- Building KMD Notarisation TX -----------------------------------------------

getNotarisationData :: ChainConf -> [EthBlock] -> NotarisationData Sha3
getNotarisationData CConf{..} blocks =
  let notarised = last blocks
      mom = trieRoot $ receiptsRootTrieTrie blocks
  
   in NOR (ethBlockHash notarised)
          (fromIntegral $ ethBlockNumber notarised)
          chainSymbol
          mom
          (fromIntegral $ length blocks)
          chainCCId
  where
    receiptsRootTrieTrie headers =
      let heights = ethBlockNumber <$> headers
          roots = ethBlockReceiptsRoot <$> headers
          keys = rlpSerialize . rlpEncode . unU256 <$> heights
       in mapToTrie $ zip keys $ unHex <$> roots

proposeInputs :: ChainConf -> [Ballot (H.PubKey, H.OutPoint)] -> [(H.PubKey, H.OutPoint)]
proposeInputs CConf{..} ballots
  | length ballots < chainNotarySigs = error "Bad error: not enough ballots"
  | otherwise = take chainNotarySigs $ bData <$> sortOn bSig ballots

getBitcoinIdent :: Hath EthNotariser BitcoinIdent
getBitcoinIdent = deriveBitcoinIdent <$> asks getSecret

getEthIdent :: Hath EthNotariser Ident
getEthIdent = do
  sk <- asks getSecret
  pure (sk, pubKeyAddr $ derivePubKey sk)

chooseUtxo :: [BitcoinUtxo] -> Maybe BitcoinUtxo
chooseUtxo = listToMaybe . choose
  where
    choose = reverse . sortOn (\c -> (utxoConfirmations c, utxoTxid c))
                     . filter ((==kmdInputAmount) . utxoAmount)

notarisationRecip :: H.ScriptOutput
notarisationRecip = H.PayPKHash $ H.getAddrHash "RXL3YXG2ceaB6C5hfJcN4fvmLH2C34knhA"

signMyInput :: H.PrvKey -> [(H.PubKey, H.OutPoint)] -> H.ScriptOutput -> H.Tx
signMyInput wif ins opret = do
  let toSigIn (a, o) = H.SigInput (H.PayPK a) o (H.SigAll False) Nothing
      inputs = toSigIn <$> ins
      outputAmount = kmdInputAmount * (fromIntegral $ length ins - 1)
      outputs = [(notarisationRecip, outputAmount), (opret, 0)]
      etx = H.buildTx (H.sigDataOP <$> inputs) outputs
      signTx tx = H.signTx tx inputs [wif]
   in either error id $ etx >>= signTx

getMyInput :: BitcoinUtxo -> H.Tx -> Maybe H.TxIn
getMyInput myUtxo tx =
  find (\txIn -> H.prevOutput txIn == getOutPoint myUtxo)
       (H.txIn tx)

compileFinalTx :: H.Tx -> [Ballot (Maybe H.TxIn)] -> H.Tx
compileFinalTx tx ballots = tx { H.txIn = mergedIns }
  where
    signedIns = catMaybes $ bData <$> ballots
    unsignedIns = H.txIn tx
    mischief = impureThrow $ ConsensusMischief $ "compileFinalTx: " ++ show (tx, ballots)
    mergedIns = map combine unsignedIns
    combine unsigned =
      case find (\a -> H.prevOutput a == H.prevOutput unsigned) signedIns of
           Nothing -> mischief
           Just signed -> unsigned { H.scriptInput = H.scriptInput signed }

