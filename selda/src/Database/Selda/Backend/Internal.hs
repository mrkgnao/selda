{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Internal backend API.
module Database.Selda.Backend.Internal
  ( StmtID, BackendID (..)
  , QueryRunner, SeldaBackend (..), SeldaConnection (..), SeldaStmt (..)
  , MonadSelda (..), SeldaT (..), SeldaM
  , SeldaError (..)
  , Param (..), Lit (..), ColAttr (..)
  , SqlType (..), SqlValue (..), SqlTypeRep (..)
  , PPConfig (..), defPPConfig
  , sqlDateTimeFormat, sqlDateFormat, sqlTimeFormat
  , freshStmtId
  , newConnection, allStmts
  , runSeldaT, seldaBackend
  ) where
import Database.Selda.Caching (invalidate)
import Database.Selda.SQL (Param (..))
import Database.Selda.SqlType
import Database.Selda.Table (Table, ColAttr (..), tableName)
import Database.Selda.SQL.Print.Config
import Database.Selda.Types (TableName)
import Control.Concurrent
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.State
import Data.Dynamic
import Data.Hashable
import qualified Data.HashMap.Strict as M
import Data.IORef
import Data.Text (Text)
import System.IO.Unsafe (unsafePerformIO)

-- | Uniquely identifies some particular backend.
--
--   When publishing a new backend, consider submitting a pull request with a
--   constructor for your backend instead of using the @Other@ constructor.
data BackendID = SQLite | PostgreSQL | Other Text
  deriving (Show, Eq, Ord)

-- | Thrown by any function in 'SeldaT' if an error occurs.
data SeldaError
  = DbError String  -- ^ Unable to open or connect to database.
  | SqlError String -- ^ An error occurred while executing query.
  deriving (Show, Eq, Typeable)

instance Exception SeldaError

-- | A prepared statement identifier. Guaranteed to be unique per application.
newtype StmtID = StmtID Int
  deriving (Show, Eq, Ord, Hashable)

-- | A connection identifier. Guaranteed to be unique per application.
newtype ConnID = ConnID Int
  deriving (Show, Eq, Ord)

{-# NOINLINE nextStmtId #-}
nextStmtId :: IORef Int
nextStmtId = unsafePerformIO $ newIORef 1

-- | Generate a fresh statement identifier, guaranteed to be unique per process.
freshStmtId :: MonadIO m => m StmtID
freshStmtId = liftIO $ atomicModifyIORef' nextStmtId $ \n -> (n+1, StmtID n)

-- | A function which executes a query and gives back a list of extensible
--   tuples; one tuple per result row, and one tuple element per column.
type QueryRunner a = Text -> [Param] -> IO a

-- | A prepared statement.
data SeldaStmt = SeldaStmt
 { -- | Backend-specific handle to the prepared statement.
   stmtHandle :: !Dynamic

   -- | The SQL code for the statement.
 , stmtText :: !Text

   -- | All parameters to be passed to the prepared statement.
   --   Parameters that are unique to each invocation are specified as indices
   --   starting at 0.
   --   Backends implementing @runPrepared@ should probably ignore this field.
 , stmtParams :: ![Either Int Param]
   
   -- | All tables touched by the statement.
 , stmtTables :: ![TableName]
 }

data SeldaConnection = SeldaConnection
  { -- | The backend used by the current connection.
    connBackend :: !SeldaBackend

    -- | A string uniquely identifying the database used by this connection.
    --   This could be, for instance, a PostgreSQL connection
    --   string or the absolute path to an SQLite file.
  , connDbId :: Text

    -- | All statements prepared for this connection.
  , connStmts :: !(IORef (M.HashMap StmtID SeldaStmt))

    -- | Is the connection closed?
  , connClosed :: !(IORef Bool)

    -- | Lock to prevent this connection from being used concurrently by
    --   multiple invocations of 'runSeldaT'.
  , connLock :: !(MVar ())
}

-- | Create a new Selda connection for the given backend and database
--   identifier string.
newConnection :: MonadIO m => SeldaBackend -> Text -> m SeldaConnection
newConnection back dbid =
  liftIO $ SeldaConnection back dbid <$> newIORef M.empty
                                     <*> newIORef False
                                     <*> newMVar ()

-- | Get all statements and their corresponding identifiers for the current
--   connection.
allStmts :: SeldaConnection -> IO [(StmtID, Dynamic)]
allStmts =
  fmap (map (\(k, v) -> (k, stmtHandle v)) . M.toList) . readIORef . connStmts

-- | A collection of functions making up a Selda backend.
data SeldaBackend = SeldaBackend
  { -- | Execute an SQL statement.
    runStmt :: Text -> [Param] -> IO (Int, [[SqlValue]])

    -- | Execute an SQL statement and return the last inserted primary key,
    --   where the primary key is auto-incrementing.
    --   Backends must take special care to make this thread-safe.
  , runStmtWithPK :: Text -> [Param] -> IO Int

    -- | Prepare a statement using the given statement identifier.
  , prepareStmt :: StmtID -> [SqlTypeRep] -> Text -> IO Dynamic

    -- | Execute a prepared statement.
  , runPrepared :: Dynamic -> [Param] -> IO (Int, [[SqlValue]])

    -- | SQL pretty-printer configuration.
  , ppConfig :: PPConfig

    -- | Close the currently open connection.
  , closeConnection :: SeldaConnection -> IO ()

    -- | Unique identifier for this backend.
  , backendId :: BackendID
  }

data SeldaState = SeldaState
  { -- | Connection in use by the current computation.
    stConnection :: !SeldaConnection

    -- | Tables modified by the current transaction.
    --   Invariant: always @Just xs@ during a transaction, and always
    --   @Nothing@ when not in a transaction.
  , stTouchedTables :: !(Maybe [TableName])
  }

-- | Some monad with Selda SQL capabilitites.
class MonadIO m => MonadSelda m where
  -- | Get the connection in use by the computation.
  seldaConnection :: m SeldaConnection

  -- | Invalidate the given table as soon as the current transaction finishes.
  --   Invalidate the table immediately if no transaction is ongoing.
  invalidateTable :: Table a -> m ()

  -- | Indicates the start of a new transaction.
  --   Starts bookkeeping to invalidate all tables modified during
  --   the transaction at the next call to 'endTransaction'.
  beginTransaction :: m ()

  -- | Indicates the end of the current transaction.
  --   Invalidates all tables that were modified since the last call to
  --   'beginTransaction', unless the transaction was rolled back.
  endTransaction :: Bool -- ^ @True@ if the transaction was committed,
                         --   @False@ if it was rolled back.
                 -> m ()

-- | Get the backend in use by the computation.
seldaBackend :: MonadSelda m => m SeldaBackend
seldaBackend = connBackend <$> seldaConnection

-- | Monad transformer adding Selda SQL capabilities.
newtype SeldaT m a = S {unS :: StateT SeldaState m a}
  deriving ( Functor, Applicative, Monad, MonadIO
           , MonadThrow, MonadCatch, MonadMask, MonadTrans
           )

instance MonadIO m => MonadSelda (SeldaT m) where
  seldaConnection = S $ fmap stConnection get

  invalidateTable tbl = S $ do
    st <- get
    case stTouchedTables st of
      Nothing -> liftIO $ invalidate [tableName tbl]
      Just ts -> put $ st {stTouchedTables = Just (tableName tbl : ts)}

  beginTransaction = S $ do
    st <- get
    case stTouchedTables st of
      Nothing -> put $ st {stTouchedTables = Just []}
      Just _  -> liftIO $ throwM $ SqlError "attempted to nest transactions"

  endTransaction committed = S $ do
    st <- get
    case stTouchedTables st of
      Just ts | committed -> liftIO $ invalidate ts
      _                   -> return ()
    put $ st {stTouchedTables = Nothing}

-- | The simplest form of Selda computation; 'SeldaT' specialized to 'IO'.
type SeldaM = SeldaT IO

-- | Run a Selda transformer. Backends should use this to implement their
--   @withX@ functions.
runSeldaT :: (MonadIO m, MonadMask m) => SeldaT m a -> SeldaConnection -> m a
runSeldaT m c = do
    liftIO $ takeMVar (connLock c)
    go `finally` liftIO (putMVar (connLock c) ())
  where
    go = do
      closed <- liftIO $ readIORef (connClosed c)
      when closed $ do
        liftIO $ throwM $ DbError "runSeldaT called with a closed connection"
      fst <$> runStateT (unS m) (SeldaState c Nothing)
