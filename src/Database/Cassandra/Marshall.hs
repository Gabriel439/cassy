{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeSynonymInstances      #-}


-----------------------------------------------------------------------------
-- |
-- Module      :
-- Copyright   :  (C) 2013 Ozgun Ataman
-- License     :  All Rights Reserved
--
-- Maintainer  :  Ozgun Ataman <oz@soostone.com>
-- Stability   :  experimental
--
-- Defines Cassandra operations for persistence of complex Haskell
-- data objects with custom-selected but implicitly performed
-- serialization.
--
-- The main design choice is to require a dictionary dictating
-- marshalling/serialization policy for every operation, rather than a
-- typeclass that can be instantiated once.
----------------------------------------------------------------------------

module Database.Cassandra.Marshall
    (

    -- * Connection
      CPool
    , Server
    , defServer
    , defServers
    , KeySpace
    , createCassandraPool

    -- * MonadCassandra Typeclass
    , MonadCassandra (..)
    , Cas
    , runCas
    , transCas
    , mapCassandra

    -- * Haskell Record Marshalling

    , Marshall (..)
    , casShow
    , casJSON
    , casBinary

    -- * Cassandra Operations
    , get
    , get_
    , getCol
    , getMulti
    , insertCol
    , insertColTTL
    , modify
    , modify_
    , delete

    -- * Necessary Types
    , ColumnName
    , ModifyOperation (..)
    , ColumnFamily
    , ConsistencyLevel (..)
    , CassandraException (..)

    -- * Filtering
    , Selector (..)
    , range
    , boundless
    , Order(..)
    , reverseOrder
    , KeySelector (..)
    , KeyRangeType (..)

    -- * Helpers
    , CKey (..)
    , fromColKey'

    -- * Working with column types
    , CasType (..)
    , TAscii (..)
    , TBytes (..)
    , TCounter (..)
    , TInt (..)
    , TInt32 (..)
    , TUtf8 (..)
    , TUUID (..)
    , TLong (..)
    , Exclusive (..)
    ) where

-------------------------------------------------------------------------------
import           Control.Error
import           Control.Exception
import           Control.Monad
import qualified Data.Aeson                 as A
import qualified Data.Attoparsec            as Atto (IResult (..), parse)
import qualified Data.Binary                as BN
import qualified Data.Binary.Get            as BN
import qualified Data.ByteString.Char8      as B
import           Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.Int                   (Int32)
import           Data.Map                   (Map)
import qualified Data.Map                   as M
import           Prelude                    hiding (catch)
-------------------------------------------------------------------------------
import           Database.Cassandra.Basic   hiding (KeySelector (..), delete,
                                             get, getCol, getMulti)
import qualified Database.Cassandra.Basic   as CB
import           Database.Cassandra.Types
-------------------------------------------------------------------------------


-- | A Haskell dictionary containing a pair of encode/decode
-- functions.
--
-- This is the main design choice in this module. We require that each
-- operation takes an explicit marshalling policy rather than a
-- typeclass which makes it possible to do it in a single way per data
-- type.
--
-- You can create your own objects of this type with great ease. Just
-- look at one of the examples here ('casJSON', 'casBinary', etc.)
data Marshall a = Marshall {
      marshallEncode :: a -> ByteString
    -- ^ An encoding function
    , marshallDecode :: ByteString -> Either String a
    -- ^ A decoding function
    }


-- | Marshall data using JSON encoding. Good interoperability, but not
-- very efficient for data storage.
casJSON :: (A.ToJSON a, A.FromJSON a) => Marshall a
casJSON = Marshall A.encode A.eitherDecode


-- | Marshall data using 'Show' and 'Read'. Not meant for serious production cases.
casShow :: (Show a, Read a) => Marshall a
casShow = Marshall
            (LB.pack . show)
            (readErr "casShow can't read cassandra value" . LB.unpack)


-- | Marshall data using the 'Binary' instance. This is one of the
-- very efficient methods available.
casBinary :: BN.Binary a => Marshall a
casBinary = Marshall BN.encode dec
    where
      dec bs = case BN.runGetOrFail BN.get bs of
                 Left (_,_,err) -> Left err
                 Right (_,_,a) -> Right a


------------------------------------------------------------------------------
-- | A modify function that will fetch a specific column, apply modification
-- function on it and save results back to Cassandra.
--
-- A 'b' side value is returned for computational convenience.
--
-- This is intended to be a workhorse function, in that you should be
-- able to do all kinds of relatively straightforward operations just
-- using this function.
--
-- This method may throw a 'CassandraException' for all exceptions other than
-- 'NotFoundException'.
modify
  :: (MonadCassandra m, CasType k)
  => Marshall a
  -- ^ A serialization methodology. Example: 'casJSON'
  -> ColumnFamily
  -> RowKey
  -> k
  -- ^ Column name; anything in CasType
  -> ConsistencyLevel
  -- ^ Read quorum
  -> ConsistencyLevel
  -- ^ Write quorum
  -> (Maybe a -> m (ModifyOperation a, b))
  -- ^ Modification function. Called with 'Just' the value if present,
  -- 'Nothing' otherwise.
  -> m b
  -- ^ Return the decided 'ModifyOperation' and its execution outcome
modify Marshall{..} cf k cn rcl wcl f =
  let
    cn' = encodeCas cn
    execF prev = do
      (fres, b) <- f prev
      case fres of
        Update a  -> insert cf k wcl [col cn' (marshallEncode a)]
        Delete    -> CB.delete cf k (ColNames [cn']) wcl
        DoNothing -> return ()
      return b
  in do
    res <- CB.getCol cf k cn' rcl
    case res of
      Nothing              -> execF Nothing
      Just Column{..}      -> execF (hush $ marshallDecode colVal)
      Just SuperColumn{..} -> throw $
        OperationNotSupported "modify not implemented for SuperColumn"


------------------------------------------------------------------------------
-- | Same as 'modify' but does not offer a side value.
--
-- This method may throw a 'CassandraException' for all exceptions other than
-- 'NotFoundException'.
modify_
  :: (MonadCassandra m, CasType k)
  => Marshall a
  -> ColumnFamily
  -> RowKey
  -> k
  -- ^ Column name; anything in CasType
  -> ConsistencyLevel
  -- ^ Read quorum
  -> ConsistencyLevel
  -- ^ Write quorum
  -> (Maybe a -> m (ModifyOperation a))
  -- ^ Modification function. Called with 'Just' the value if present,
  -- 'Nothing' otherwise.
  -> m ()
modify_ m cf k cn rcl wcl f =
  let
    f' prev = do
      op <- f prev
      return (op, ())
  in do
      modify m cf k cn rcl wcl f'
      return ()


-------------------------------------------------------------------------------
-- Simple insertion function making use of typeclasses
insertCol
    :: (MonadCassandra m, CasType k)
    => Marshall a
    -> ColumnFamily
    -> RowKey
    -> k
    -- ^ Column name. See 'CasType' for what you can use here.
    -> ConsistencyLevel
    -> a -- ^ Content
    -> m ()
insertCol Marshall{..} cf rk cn cl a =
    insert cf rk cl [packCol (cn, marshallEncode a)]



-------------------------------------------------------------------------------
-- Simple insertion function making use of typeclasses
insertColTTL
    :: (MonadCassandra m, CasType k)
    => Marshall a
    -> ColumnFamily
    -> RowKey
    -> k
    -- ^ Column name. See 'CasType' for what you can use here.
    -> ConsistencyLevel
    -> a
    -- ^ Content
    -> Int32
    -- ^ TTL for this column
    -> m ()
insertColTTL Marshall{..} cf rk cn cl a ttl = insert cf rk cl [column]
    where
      column = Column (packKey cn) (marshallEncode a) Nothing (Just ttl)


------------------------------------------------------------------------------
-- | An arbitrary get operation - slice with 'Selector'.
--
-- Internally based on Basic.get. Table is assumed to be a regular
-- ColumnFamily and contents of returned columns are cast into the
-- target type.
get
    :: (MonadCassandra m, CasType k)
    => Marshall a
    -> ColumnFamily
    -> RowKey
    -> Selector
    -- ^ A slice selector
    -> ConsistencyLevel
    -> m [(k, a)]
    -- ^ List of key-value pairs. See 'CasType' for what key types you can use.
get m cf k s cl = do
  res <- CB.get cf k s cl
  return $ map (col2val m) res


-------------------------------------------------------------------------------
-- | A version of 'get' that discards the column names for the common
-- scenario. Useful because you would otherwise be forced to manually
-- supply type signatures to get rid of the 'CasType' ambiguity.
get_
    :: (MonadCassandra m)
    => Marshall a
    -> ColumnFamily
    -> RowKey
    -> Selector
    -- ^ A slice selector
    -> ConsistencyLevel
    -> m [a]
get_ m cf k s cl = do
    (res :: [(LB.ByteString, a)]) <- get m cf k s cl
    return $ map snd res


-------------------------------------------------------------------------------
ksToBasicKS :: KeySelector -> CB.KeySelector
ksToBasicKS (Keys k) = CB.Keys $ map toColKey k
ksToBasicKS (KeyRange ty fr to i) = CB.KeyRange ty (toColKey fr) (toColKey to) i


-------------------------------------------------------------------------------
-- | Get a slice of columns from multiple rows at once. Note that
-- since we are auto-serializing from JSON, all the columns must be of
-- the same data type.
getMulti
    :: (MonadCassandra m)
    => Marshall a
    -> ColumnFamily
    -> KeySelector
    -> Selector
    -> ConsistencyLevel
    -> m (Map RowKey [(ColumnName, a)])
getMulti m cf ks s cl = do
  res <- CB.getMulti cf (ksToBasicKS ks) s cl
  return . M.fromList . map conv . M.toList $ res
  where
    conv (k, row) = (k, map (col2val m) row)


-------------------------------------------------------------------------------
-- | Get a single column from a single row
getCol
    :: (MonadCassandra m, CasType k)
    => Marshall a
    -> ColumnFamily
    -> RowKey
    -> k
    -- ^ Column name; anything in 'CasType'
    -> ConsistencyLevel
    -> m (Maybe a)
getCol m cf rk ck cl = do
    res <- CB.getCol cf rk (encodeCas ck) cl
    case res of
      Nothing -> return Nothing
      Just res' -> do
          let (_ :: ByteString, x) = col2val m res'
          return $ Just x


------------------------------------------------------------------------------
-- | Same as the 'delete' in the 'Cassandra.Basic' module, except that
-- it throws an exception rather than returning an explicit Either
-- value.
delete
  :: (MonadCassandra m)
  => ColumnFamily
  -- ^ In 'ColumnFamily'
  -> RowKey
  -- ^ Key to be deleted
  -> Selector
  -- ^ Columns to be deleted
  -> ConsistencyLevel
  -> m ()
delete cf k s cl = CB.delete cf k s cl


-------------------------------------------------------------------------------
-- | Convert regular column to a key-value pair
col2val :: CasType k => Marshall a -> Column -> (k, a)
col2val Marshall{..} c = f $ unpackCol c
    where
      f (k, val) = (k, either err id $ marshallDecode val)
      err s = error $ "Cassandra Marshall: Value can't be decoded: " ++ s
col2val _ _ = error "col2val is not implemented for SuperColumns"

