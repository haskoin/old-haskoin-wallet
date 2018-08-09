{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
module Network.Haskoin.Wallet.Server
( runSPVServer
, runSPVServerWithContext
) where

import           Control.Concurrent.Async.Lifted       (async, link,
                                                        waitAnyCancel)
import           Control.Concurrent.STM                (atomically, retry)
import           Control.Concurrent.STM.TBMChan        (TBMChan, newTBMChan,
                                                        readTBMChan)
import           Control.DeepSeq                       (NFData (..))
import           Control.Exception.Lifted              (ErrorCall (..),
                                                        SomeException (..),
                                                        catches)
import qualified Control.Exception.Lifted              as E (Handler (..))
import           Control.Monad                         (forM_, forever, unless,
                                                        void, when)
import           Control.Monad.Base                    (MonadBase)
import           Control.Monad.Catch                   (MonadThrow)
import           Control.Monad.Fix                     (fix)
import           Control.Monad.Logger                  (MonadLoggerIO,
                                                        filterLogger, logDebug,
                                                        logError, logInfo,
                                                        logWarn,
                                                        runStdoutLoggingT)
import           Control.Monad.Trans                   (lift, liftIO)
import           Control.Monad.Trans.Control           (MonadBaseControl,
                                                        liftBaseOpDiscard)
import           Control.Monad.Trans.Resource          (MonadResource,
                                                        runResourceT)
import           Data.Aeson                            (Value, decode, encode)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString.Lazy                  as BL (fromStrict,
                                                              toStrict)
import           Data.Conduit                          (await, awaitForever,
                                                        ($$))
import qualified Data.HashMap.Strict                   as H (lookup)
import           Data.List.NonEmpty                    (NonEmpty ((:|)))
import qualified Data.Map.Strict                       as M (Map, assocs, elems,
                                                             empty,
                                                             fromListWith, null,
                                                             unionWith)
import           Data.Maybe                            (fromJust, fromMaybe,
                                                        isJust)
import           Data.Monoid                           ((<>))
import           Data.String.Conversions               (cs)
import           Data.Text                             (pack)
import           Data.Word                             (Word32)
import           Database.Esqueleto                    (from, val, where_,
                                                        (&&.), (<=.), (==.),
                                                        (^.))
import           Database.Persist.Sql                  (ConnectionPool,
                                                        runMigration)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Node.BlockChain
import           Network.Haskoin.Node.HeaderTree
import           Network.Haskoin.Node.Peer
import           Network.Haskoin.Node.STM
import           Network.Haskoin.Transaction
import           Network.Haskoin.Wallet.Accounts
import           Network.Haskoin.Wallet.Database
import           Network.Haskoin.Wallet.Model
import           Network.Haskoin.Wallet.Server.Handler
import           Network.Haskoin.Wallet.Settings
import           Network.Haskoin.Wallet.Transaction
import           Network.Haskoin.Wallet.Types
import           System.Posix.Daemon                   (Redirection (ToFile),
                                                        runDetached)
import           System.ZMQ4                           (Context, KeyFormat (..),
                                                        Pub (..), Rep (..),
                                                        Socket, bind, receive,
                                                        receiveMulti, restrict,
                                                        send, sendMulti,
                                                        setCurveSecretKey,
                                                        setCurveServer,
                                                        setLinger, withContext,
                                                        withSocket, z85Decode)

data EventSession = EventSession
    { eventBatchSize :: !Int
    , eventNewAddrs  :: !(M.Map AccountId Word32)
    }
    deriving (Eq, Show, Read)

instance NFData EventSession where
    rnf EventSession{..} =
        rnf eventBatchSize `seq`
        rnf (M.elems eventNewAddrs)

runSPVServer :: Config -> IO ()
runSPVServer cfg = maybeDetach cfg $ -- start the server process
    withContext (run . runSPVServerWithContext cfg)
  where
    -- Setup logging monads
    run          = runResourceT . runLogging
    runLogging   = runStdoutLoggingT . filterLogger logFilter
    logFilter _ level = level >= configLogLevel cfg

-- |Run the server, and use the specifed ZeroMQ context.
--  Useful if you want to communicate with the server using
--  the "inproc" ZeroMQ transport, where a shared context is
--  required.
runSPVServerWithContext :: ( MonadLoggerIO m
                           , MonadBaseControl IO m
                           , MonadBase IO m
                           , MonadThrow m
                           , MonadResource m
                           )
                        => Config -> Context -> m ()
runSPVServerWithContext cfg ctx = do
    -- Initialize the database
    -- Check the operation mode of the server.
    pool <- initDatabase cfg
    -- Notification channel
    notif <- liftIO $ atomically $ newTBMChan 1000
    case configMode cfg of
        -- In this mode, we do not launch an SPV node. We only accept
        -- client requests through the ZMQ API.
        SPVOffline -> do
            let session = HandlerSession cfg pool Nothing notif
            as <- mapM async
                -- Run the ZMQ API-command server
                [ runWalletCmd ctx session
                -- Run the ZMQ notification thread
                , runWalletNotif ctx session
                ]
            mapM_ link as
            (_,r) <- waitAnyCancel as
            return r
        -- In this mode, we launch the client ZMQ API and we sync the
        -- wallet database with an SPV node.
        SPVOnline -> do
            -- Initialize the node state
            node <- getNodeState (Right pool)
            -- Spin up the node threads
            let session = HandlerSession cfg pool (Just node) notif
            as <- mapM async
                -- Start the SPV node
                [ runNodeT (spv pool) node
                -- Merkle block synchronization
                , runNodeT (runMerkleSync pool notif) node
                -- Import solo transactions as they arrive from peers
                , runNodeT (txSource $$ processTx pool notif) node
                -- Respond to transaction GetData requests
                , runNodeT (handleGetData $ (`runDBPool` pool) . getTx) node
                -- Re-broadcast pending transactions
                , runNodeT (broadcastPendingTxs pool) node
                -- Run the ZMQ API-command server
                , runWalletCmd ctx session
                -- Run the ZMQ notification thread
                , runWalletNotif ctx session
                ]
            mapM_ link as
            (_,r) <- waitAnyCancel as
            $(logDebug) "Exiting main thread"
            return r
  where
    spv pool = do
        -- Get our bloom filter
        (bloom, elems, _) <- runDBPool getBloomFilter pool
        startSPVNode hosts bloom elems
        -- Bitcoin nodes to connect to
    nodes = fromMaybe
        (error $ "BTC nodes for " ++ networkName ++ " not found")
        (pack networkName `H.lookup` configBTCNodes cfg)
    hosts = map (\x -> PeerHost (btcNodeHost x) (btcNodePort x)) nodes
    -- Run the merkle syncing thread
    runMerkleSync pool notif = do
        $(logDebug) "Waiting for a valid bloom filter for merkle downloads..."

        -- Only download merkles if we have a valid bloom filter
        _ <- atomicallyNodeT waitBloomFilter

        -- Provide a fast catchup time if we are at height 0
        fcM <- fmap (fmap adjustFCTime) $ (`runDBPool` pool) $ do
            (_, h) <- walletBestBlock
            if h == 0 then firstAddrTime else return Nothing
        maybe (return ()) (atomicallyNodeT . rescanTs) fcM

        -- Start the merkle sync
        merkleSync pool 500 notif
        $(logDebug) "Exiting Merkle-sync thread"
    -- Run a thread that will re-broadcast pending transactions
    broadcastPendingTxs pool = forever $ do
        (hash, _) <- runSqlNodeT $ walletBestBlock
        -- Wait until we are synced
        atomicallyNodeT $ do
            synced <- areBlocksSynced hash
            unless synced $ lift retry
        -- Send an INV for those transactions to all peers
        broadcastTxs =<< runDBPool (getPendingTxs 0) pool
        -- Wait until we are not synced
        atomicallyNodeT $ do
            synced <- areBlocksSynced hash
            when synced $ lift retry
        $(logDebug) "Exiting tx-broadcast thread"
    processTx pool notif = do
        awaitForever $ \tx -> lift $ do
            (_, newAddrs) <- runDBPool (importNetTx tx (Just notif)) pool
            unless (null newAddrs) $ do
                $(logInfo) $ pack $ unwords
                    [ "Generated", show $ length newAddrs
                    , "new addresses while importing the tx."
                    , "Updating the bloom filter"
                    ]
                (bloom, elems, _) <- runDBPool getBloomFilter pool
                atomicallyNodeT $ sendBloomFilter bloom elems
        $(logDebug) "Exiting tx-import thread"

initDatabase :: (MonadBaseControl IO m, MonadLoggerIO m)
             => Config -> m ConnectionPool
initDatabase cfg = do
    -- Create a database pool
    let dbCfg = fromMaybe
            (error $ "DB config settings for " ++ networkName ++ " not found")
            (pack networkName `H.lookup` configDatabase cfg)
    pool <- getDatabasePool dbCfg
    -- Initialize wallet database
    flip runDBPool pool $ do
        _ <- runMigration migrateWallet
        _ <- runMigration migrateHeaderTree
        initWallet $ configBloomFP cfg
    return pool

merkleSync
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m, MonadResource m)
    => ConnectionPool
    -> Word32
    -> TBMChan Notif
    -> NodeT m ()
merkleSync pool bSize notif = do
    -- Get our best block
    (hash, _) <- runDBPool walletBestBlock pool
    $(logDebug) "Starting merkle batch download"
    -- Wait for a new block or a rescan
    (action, source) <- merkleDownload hash bSize
    $(logDebug) "Received a merkle action and source. Processing the source..."

    -- Read and process the data from the source
    (lastMerkleM, mTxsAcc, aMap) <- source $$ go Nothing [] M.empty
    $(logDebug) "Merkle source processed and closed"

    -- Send a new bloom filter to our peers if new addresses were generated
    unless (M.null aMap) $ do
        $(logInfo) $ pack $ unwords
            [ "Generated", show $ sum $ M.elems aMap
            , "new addresses while importing the merkle block."
            , "Sending our bloom filter."
            ]
        (bloom, elems, _) <- runDBPool getBloomFilter pool
        atomicallyNodeT $ sendBloomFilter bloom elems

    -- Check if we should rescan the current merkle batch
    $(logDebug) "Checking if we need to rescan the current batch..."
    rescan <- shouldRescan aMap
    when rescan $ $(logDebug) "We need to rescan the current batch"
    -- Compute the new batch size
    let newBSize | rescan    = max 1 $ bSize `div` 2
                 | otherwise = min 500 $ bSize + max 1 (bSize `div` 20)

    when (newBSize /= bSize) $ $(logDebug) $ pack $ unwords
        [ "Changing block batch size from", show bSize, "to", show newBSize ]

    -- Did we receive all the merkles that we asked for ?
    let missing = (headerHash <$> lastMerkleM) /=
            Just (nodeHash $ last $ actionNodes action)

    when missing $ $(logWarn) $ pack $ unwords
        [ "Merkle block stream closed prematurely"
        , show lastMerkleM
        ]

    -- TODO: We could still salvage a partially received batch
    unless (rescan || missing) $ do
        $(logDebug) "Importing merkles into the wallet..."
        -- Confirm the transactions
        runDBPool (importMerkles action mTxsAcc (Just notif)) pool
        $(logDebug) "Done importing merkles into the wallet"
        logBlockChainAction action

    merkleSync pool newBSize notif
  where
    go lastMerkleM mTxsAcc aMap = await >>= \resM -> case resM of
        Just (Right tx) -> do
            $(logDebug) $ pack $ unwords
                [ "Importing merkle tx", cs $ txHashToHex $ txHash tx ]
            (_, newAddrs) <- lift $ runDBPool (importNetTx tx Nothing) pool
            $(logDebug) $ pack $ unwords
                [ "Generated", show $ length newAddrs
                , "new addresses while importing tx"
                , cs $ txHashToHex $ txHash tx
                ]
            let newMap = M.unionWith (+) aMap $ groupByAcc newAddrs
            go lastMerkleM mTxsAcc newMap
        Just (Left (MerkleBlock mHead _ _ _, mTxs)) -> do
            $(logDebug) $ pack $ unwords
                [ "Buffering merkle block"
                , cs $ blockHashToHex $ headerHash mHead
                ]
            go (Just mHead) (mTxs:mTxsAcc) aMap
        -- Done processing this batch. Reverse mTxsAcc as we have been
        -- prepending new values to it.
        _ -> return (lastMerkleM, reverse mTxsAcc, aMap)
    groupByAcc addrs =
        let xs = map (\a -> (walletAddrAccount a, 1)) addrs
        in  M.fromListWith (+) xs
    shouldRescan aMap = do
        -- Try to find an account whos gap is smaller than the number of new
        -- addresses generated in that account.
        res <- (`runDBPool` pool) $ splitSelect (M.assocs aMap) $ \ks ->
            from $ \a -> do
                let andCond (ai, cnt) =
                        a ^. AccountId ==. val ai &&.
                        a ^. AccountGap <=. val cnt
                where_ $ join2 $ map andCond ks
                return $ a ^. AccountId
        return $ not $ null res
    -- Some logging of the blocks
    logBlockChainAction action = case action of
        BestChain nodes -> $(logInfo) $ pack $ unwords
            [ "Best chain height"
            , show $ nodeBlockHeight $ last nodes
            , "(", cs $ blockHashToHex $ nodeHash $ last nodes
            , ")"
            ]
        ChainReorg _ o n -> $(logInfo) $ pack $ unlines $
            [ "Chain reorg."
            , "Orphaned blocks:"
            ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) o
            ++ [ "New blocks:" ]
            ++ map (("  " ++) . cs . blockHashToHex . nodeHash) n
            ++ [ unwords [ "Best merkle chain height"
                        , show $ nodeBlockHeight $ last n
                        ]
            ]
        SideChain n -> $(logWarn) $ pack $ unlines $
            "Side chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n
        KnownChain n -> $(logWarn) $ pack $ unlines $
            "Known chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n

maybeDetach :: Config -> IO () -> IO ()
maybeDetach cfg action =
    if configDetach cfg then runDetached pidFile logFile action >> logStarted else action
  where
    logStarted = putStrLn "Process started"
    pidFile = Just $ configPidFile cfg
    logFile = ToFile $ configLogFile cfg

-- Run the main ZeroMQ loop
-- TODO: Support concurrent requests using DEALER socket when we can do
-- concurrent MySQL requests.
runWalletNotif :: ( MonadLoggerIO m
                , MonadBaseControl IO m
                , MonadBase IO m
                , MonadThrow m
                , MonadResource m
                )
               => Context -> HandlerSession -> m ()
runWalletNotif ctx session =
    liftBaseOpDiscard (withSocket ctx Pub) $ \sock -> do
        liftIO $ setLinger (restrict (0 :: Int)) sock
        setupCrypto ctx sock session
        liftIO $ bind sock $ configBindNotif $ handlerConfig session
        forever $ do
            xM <- liftIO $ atomically $ readTBMChan $ handlerNotifChan session
            forM_ xM $ \x ->
                let (typ, pay) = case x of
                        NotifBlock _ ->
                            ("[block]", cs $ encode x)
                        NotifTx JsonTx{..} ->
                            ("{" <> cs jsonTxAccount <> "}", cs $ encode x)
                in liftIO $ sendMulti sock $ typ :| [pay]

runWalletCmd :: ( MonadLoggerIO m
                , MonadBaseControl IO m
                , MonadBase IO m
                , MonadThrow m
                , MonadResource m
                )
             => Context -> HandlerSession -> m ()
runWalletCmd ctx session = do
    liftBaseOpDiscard (withSocket ctx Rep) $ \sock -> do
        liftIO $ setLinger (restrict (0 :: Int)) sock
        setupCrypto ctx sock session
        liftIO $ bind sock $ configBind $ handlerConfig session
        fix $ \loop -> do
            bs  <- liftIO $ receive sock
            let msg = decode $ BL.fromStrict bs
            res <- case msg of
                Just r  -> catchErrors $
                    runHandler (dispatchRequest r) session
                Nothing -> return $ ResponseError "Could not decode request"
            liftIO $ send sock [] $ BL.toStrict $ encode res
            unless (msg == Just StopServerReq) loop
    $(logInfo) "Exiting ZMQ command thread..."
  where
    catchErrors m = catches m
        [ E.Handler $ \(WalletException err) -> do
            $(logError) $ pack err
            return $ ResponseError $ pack err
        , E.Handler $ \(ErrorCall err) -> do
            $(logError) $ pack err
            return $ ResponseError $ pack err
        , E.Handler $ \(SomeException exc) -> do
            $(logError) $ pack $ show exc
            return $ ResponseError $ pack $ show exc
        ]

setupCrypto :: (MonadLoggerIO m, MonadBaseControl IO m)
            => Context -> Socket a -> HandlerSession -> m ()
setupCrypto ctx' sock session = do
    when (isJust serverKeyM) $ liftIO $ do
        let k = fromJust $ configServerKey $ handlerConfig session
        setCurveServer True sock
        setCurveSecretKey TextFormat k sock
    when (isJust clientKeyPubM) $ do
        k <- z85Decode (fromJust clientKeyPubM)
        void $ async $ runZapAuth ctx' k
  where
    cfg = handlerConfig session
    serverKeyM = configServerKey cfg
    clientKeyPubM = configClientKeyPub cfg

runZapAuth :: ( MonadLoggerIO m
              , MonadBaseControl IO m
              , MonadBase IO m
              )
           => Context -> ByteString -> m ()
runZapAuth ctx k = do
    $(logDebug) $ "Starting ØMQ authentication thread"
    liftBaseOpDiscard (withSocket ctx Rep) $ \zap -> do
        liftIO $ setLinger (restrict (0 :: Int)) zap
        liftIO $ bind zap "inproc://zeromq.zap.01"
        forever $ do
            buffer <- liftIO $ receiveMulti zap
            let actionE =
                    case buffer of
                      v:q:_:_:_:m:p:_ -> do
                          when (v /= "1.0") $
                              Left (q, "500", "Version number not valid")
                          when (m /= "CURVE") $
                              Left (q, "400", "Mechanism not supported")
                          when (p /= k) $
                              Left (q, "400", "Invalid client public key")
                          return q
                      _ -> Left ("", "500", "Malformed request")
            case actionE of
              Right q -> do
                  $(logInfo) "Authenticated client successfully"
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, "200", "OK", "client", ""]
              Left (q, c, m) -> do
                  $(logError) $ pack $ unwords
                      [ "Failed to authenticate client:" , cs c, cs m ]
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, c, m, "", ""]


dispatchRequest :: ( MonadLoggerIO m
                   , MonadBaseControl IO m
                   , MonadBase IO m
                   , MonadThrow m
                   , MonadResource m
                   )
                => WalletRequest -> Handler m (WalletResponse Value)
dispatchRequest req = fmap ResponseValid $ case req of
    AccountReq n              -> accountReq n
    AccountsReq p             -> accountsReq p
    NewAccountReq na          -> newAccountReq na
    RenameAccountReq n n'     -> renameAccountReq n n'
    AddPubKeysReq n ks        -> addPubKeysReq n ks
    SetAccountGapReq n g      -> setAccountGapReq n g
    AddrsReq n t m o p        -> addrsReq n t m o p
    UnusedAddrsReq n t p      -> unusedAddrsReq n t p
    AddressReq n i t m o      -> addressReq n i t m o
    PubKeyIndexReq n k t      -> pubKeyIndexReq n k t
    SetAddrLabelReq n i t l   -> setAddrLabelReq n i t l
    GenerateAddrsReq n i t    -> generateAddrsReq n i t
    TxsReq n p                -> txsReq n p
    PendingTxsReq a p         -> pendingTxsReq a p
    DeadTxsReq a p            -> deadTxsReq a p
    AddrTxsReq n i t p        -> addrTxsReq n i t p
    CreateTxReq n c           -> createTxReq n c
    ImportTxReq n t           -> importTxReq n t
    SignTxReq n s             -> signTxReq n s
    TxReq n h                 -> txReq n h
    DeleteTxReq t             -> deleteTxReq t
    OfflineTxReq n h          -> offlineTxReq n h
    SignOfflineTxReq n k t c  -> signOfflineTxReq n k t c
    BalanceReq n mc o         -> balanceReq n mc o
    NodeActionReq na          -> nodeActionReq na
    SyncReq a n b             -> syncReq a (Right n) b
    SyncHeightReq a n b       -> syncReq a (Left n) b
    BlockInfoReq l            -> blockInfoReq l
    StopServerReq             -> stopServerReq

