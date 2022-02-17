{-# LANGUAGE GADTs #-}
module Cardano.Benchmarking.Compiler
where

import           Prelude

import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Except
import           Control.Monad.Trans.RWS.CPS

import           Data.Dependent.Sum ( (==>) )
import           Data.DList (DList)
import qualified Data.DList as DL

-- import           Cardano.Api (Lovelace)
import           Cardano.Benchmarking.Types
import           Cardano.Benchmarking.NixOptions
import           Cardano.Benchmarking.Script.Setters
import           Cardano.Benchmarking.Script.Store (Name(..))
import           Cardano.Benchmarking.Script.Types

data CompileError where
  SomeCompilerError :: CompileError

type Compiler a = ExceptT CompileError (RWS NixServiceOptions (DList Action) ()) a

compileToScript :: Compiler ()
compileToScript = do
  initConstants
  emit . StartProtocol =<< askNixOption _nix_nodeConfigFile
  importGenesisFunds
  initCollaterals
  splittingPhase
  benchmarkingPhase

initConstants :: Compiler ()
initConstants = do
  setN TNumberOfInputsPerTx  _nix_inputs_per_tx
  setN TNumberOfOutputsPerTx _nix_outputs_per_tx
  setN TNumberOfTxs          _nix_tx_count
  setN TTxAdditionalSize     _nix_add_tx_size
  setN TMinValuePerUTxO      _nix_min_utxo_value
  setN TFee                  _nix_tx_fee
  setN TEra                  _nix_era
  setN TTargets              _nix_targetNodes
  setN TLocalSocket          _nix_localNodeSocketPath
  setConst  TTTL             1000000
  where
    setConst :: Tag v -> v -> Compiler ()
    setConst key val = emit $ Set $ key ==> val 

    setN :: Tag v -> (NixServiceOptions -> v) -> Compiler ()
    setN key s = askNixOption s >>= setConst key

importGenesisFunds :: Compiler ()
importGenesisFunds = do
  cmd1 (ReadSigningKey $ KeyName "pass-partout") _nix_sigKey
  emit $ ImportGenesisFund LocalSocket (KeyName "pass-partout") (KeyName "pass-partout")
  delay

initCollaterals :: Compiler ()
initCollaterals = undefined

splittingPhase :: Compiler ()
splittingPhase = undefined

benchmarkingPhase :: Compiler ()
benchmarkingPhase = undefined

{-
evilFeeMagic :: Compiler ()
evilFeeMagic = do
  tx_fee <- askNixOption _nix_tx_fee
  plutusMode <- askNixOption _nix_plutusMode  
  (NumberOfInputsPerTx inputs_per_tx) <- askNixOption _nix_inputs_per_tx
  (NumberOfOutputsPerTx outputs_per_tx) <- askNixOption _nix_outputs_per_tx  
  min_utxo_value  <- askNixOption _nix_min_utxo_value
  let
    scriptFees = 5000000;
    collateralPercentage = 200;

    totalFee = if plutusMode
               then tx_fee + scriptFees * inputs_per_tx
               else tx_fee;
    safeCollateral = max ((scriptFees + tx_fee) * collateralPercentage / 100) min_utxo_value;
    minTotalValue = min_utxo_value * outputs_per_tx + totalFee;
    minValuePerInput = minTotalValue / inputs_per_tx + 1;
  return ()
-}

emit :: Action -> Compiler ()
emit = lift . tell . DL.singleton

cmd1 :: (v -> Action) -> (NixServiceOptions -> v) -> Compiler ()
cmd1 cmd arg = emit . cmd =<< askNixOption arg
  
askNixOption :: (NixServiceOptions -> v) -> Compiler v
askNixOption = lift . asks

delay :: Compiler ()
delay = cmd1 Delay _nix_init_cooldown
