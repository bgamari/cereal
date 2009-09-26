-----------------------------------------------------------------------------
-- |
-- Module      : Data.Serialize.Put
-- Copyright   : Lennart Kolmodin
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Trevor Elliott <trevor@galois.com>
-- Stability   :
-- Portability :
--
-- The Put monad. A monad for efficiently constructing lazy bytestrings.
--
-----------------------------------------------------------------------------

module Data.Serialize.Put (

    -- * The Put type
      Put
    , PutM(..)
    , Putter
    , runPut
    , runPutM
    , putBuilder
    , execPut

    -- * Flushing the implicit parse state
    , flush

    -- * Primitives
    , putWord8
    , putByteString
    , putLazyByteString

    -- * Big-endian primitives
    , putWord16be
    , putWord32be
    , putWord64be

    -- * Little-endian primitives
    , putWord16le
    , putWord32le
    , putWord64le

    -- * Host-endian, unaligned writes
    , putWordhost
    , putWord16host
    , putWord32host
    , putWord64host

    -- * Containers
    , putTwoOf
    , putListOf
    , putIArrayOf
    , putSeqOf
    , putTreeOf
    , putMapOf

  ) where

import Data.Serialize.Builder (Builder, toByteString)
import qualified Data.Serialize.Builder as B

import Control.Applicative
import Data.Array.Unboxed
import Data.Ix
import Data.Monoid
import Data.Word
import qualified Data.ByteString        as S
import qualified Data.ByteString.Lazy   as L
import qualified Data.Map               as Map
import qualified Data.Sequence          as Seq
import qualified Data.Tree              as T


------------------------------------------------------------------------

-- XXX Strict in buffer only. 
data PairS a = PairS a {-# UNPACK #-}!Builder

sndS :: PairS a -> Builder
sndS (PairS _ b) = b

-- | The PutM type. A Writer monad over the efficient Builder monoid.
newtype PutM a = Put { unPut :: PairS a }

-- | Put merely lifts Builder into a Writer monad, applied to ().
type Put = PutM ()

type Putter a = a -> Put

instance Functor PutM where
        fmap f m = Put $ let PairS a w = unPut m in PairS (f a) w

instance Applicative PutM where
        pure    = return
        m <*> k = Put $
            let PairS f w  = unPut m
                PairS x w' = unPut k
            in PairS (f x) (w `mappend` w')

instance Monad PutM where
    return a = Put (PairS a mempty)

    m >>= k  = Put $
        let PairS a w  = unPut m
            PairS b w' = unPut (k a)
        in PairS b (w `mappend` w')

    m >> k  = Put $
        let PairS _ w  = unPut m
            PairS b w' = unPut k
        in PairS b (w `mappend` w')

tell :: Putter Builder
tell b = Put $ PairS () b

putBuilder :: Putter Builder
putBuilder = tell

-- | Run the 'Put' monad
execPut :: PutM a -> Builder
execPut = sndS . unPut

-- | Run the 'Put' monad with a serialiser
runPut :: Put -> S.ByteString
runPut = toByteString . sndS . unPut

-- | Run the 'Put' monad with a serialiser and get its result
runPutM :: PutM a -> (a, S.ByteString)
runPutM (Put (PairS f s)) = (f, toByteString s)

------------------------------------------------------------------------

-- | Pop the ByteString we have constructed so far, if any, yielding a
-- new chunk in the result ByteString.
flush               :: Put
flush               = tell B.flush

-- | Efficiently write a byte into the output buffer
putWord8            :: Putter Word8
putWord8            = tell . B.singleton

-- | An efficient primitive to write a strict ByteString into the output buffer.
-- It flushes the current buffer, and writes the argument into a new chunk.
putByteString       :: Putter S.ByteString
putByteString       = tell . B.fromByteString

-- | Write a lazy ByteString efficiently, simply appending the lazy
-- ByteString chunks to the output buffer
putLazyByteString   :: Putter L.ByteString
putLazyByteString   = tell . B.fromLazyByteString

-- | Write a Word16 in big endian format
putWord16be         :: Putter Word16
putWord16be         = tell . B.putWord16be

-- | Write a Word16 in little endian format
putWord16le         :: Putter Word16
putWord16le         = tell . B.putWord16le

-- | Write a Word32 in big endian format
putWord32be         :: Putter Word32
putWord32be         = tell . B.putWord32be

-- | Write a Word32 in little endian format
putWord32le         :: Putter Word32
putWord32le         = tell . B.putWord32le

-- | Write a Word64 in big endian format
putWord64be         :: Putter Word64
putWord64be         = tell . B.putWord64be

-- | Write a Word64 in little endian format
putWord64le         :: Putter Word64
putWord64le         = tell . B.putWord64le

------------------------------------------------------------------------

-- | /O(1)./ Write a single native machine word. The word is
-- written in host order, host endian form, for the machine you're on.
-- On a 64 bit machine the Word is an 8 byte value, on a 32 bit machine,
-- 4 bytes. Values written this way are not portable to
-- different endian or word sized machines, without conversion.
--
putWordhost         :: Putter Word
putWordhost         = tell . B.putWordhost

-- | /O(1)./ Write a Word16 in native host order and host endianness.
-- For portability issues see @putWordhost@.
putWord16host       :: Putter Word16
putWord16host       = tell . B.putWord16host

-- | /O(1)./ Write a Word32 in native host order and host endianness.
-- For portability issues see @putWordhost@.
putWord32host       :: Putter Word32
putWord32host       = tell . B.putWord32host

-- | /O(1)./ Write a Word64 in native host order
-- On a 32 bit machine we write two host order Word32s, in big endian form.
-- For portability issues see @putWordhost@.
putWord64host       :: Putter Word64
putWord64host       = tell . B.putWord64host


-- Containers ------------------------------------------------------------------

putTwoOf :: Putter a -> Putter b -> Putter (a,b)
putTwoOf pa pb (a,b) = pa a >> pb b

putListOf :: Putter a -> Putter [a]
putListOf pa = go 0 (return ())
  where
  go n body []     = putWord64be n >> body
  go n body (x:xs) = n' `seq` go n' (body >> pa x) xs
    where n' = n + 1

putIArrayOf :: (Ix i, IArray a e) => Putter i -> Putter e -> Putter (a i e)
putIArrayOf pix pe a = do
  putTwoOf pix pix (bounds a)
  putListOf pe (elems a)

putSeqOf :: Putter a -> Putter (Seq.Seq a)
putSeqOf pa = go 0 (return ())
  where
  go n body s = case Seq.viewl s of
    Seq.EmptyL  -> putWord64be n >> body
    a Seq.:< as -> n' `seq` go n' (body >> pa a) as
      where n' = n + 1

putTreeOf :: Putter a -> Putter (T.Tree a)
putTreeOf pa (T.Node r s) = pa r >> putListOf (putTreeOf pa) s

putMapOf :: Ord k => Putter k -> Putter a -> Putter (Map.Map k a)
putMapOf pk pa = putListOf (putTwoOf pk pa) . Map.toAscList
