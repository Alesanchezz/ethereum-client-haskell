{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Blockchain.VM.Memory (
  Memory(..),
  getSizeInBytes,
  getSizeInWords,
  getShow,
  getMemAsByteString,
  mLoad,
  mLoad8,
  mLoadByteString,
  mStore,
  mStore8,
  mStoreByteString
  ) where

import Control.Monad
import qualified Data.Vector.Unboxed.Mutable as V
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import Data.Functor
import Data.IORef
import Data.Word
--import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Blockchain.ExtWord
import Blockchain.Util
import Blockchain.VM.VMState

safeRead::V.IOVector Word8->Word256->IO Word8
safeRead _ x | x > 0x7fffffffffffffff = return 0 --There is no way that memory will be filled up this high, it would cost too much gas.  I think it is safe to assume it is zero.
--safeRead _ x | x > 0x7fffffffffffffff = error "error in safeRead, value too large"
safeRead mem x = do
  let len = V.length mem
  if x < fromIntegral len
    then V.read mem (fromIntegral x)
    else return 0

--Word256 is too big to use for [first..first+size-1], so use safeRange instead
safeRange::Word256->Word256->[Word256]
safeRange first 0 = []
safeRange first size = first:safeRange (first+1) (size-1)

hasException::VMState->Bool
hasException VMState{vmException=Just _} = True
hasException _ = False

getSizeInWords::Memory->IO Word256
getSizeInWords (Memory _ size) = (ceiling . (/ (32::Double)) . fromIntegral) <$> readIORef size

getSizeInBytes::Memory->IO Word256
getSizeInBytes (Memory _ size) = readIORef size

--In this function I use the words "size" and "length" to mean 2 different things....
--"size" is the highest memory location used (as described in the yellowpaper).
--"length" is the IOVector length, which will often be larger than the size.
--Basically, to avoid resizing the vector constantly (which could be expensive),
--I keep something larger around until it fills up, then reallocate (something even
--larger).
setNewMaxSize::VMState->Integer->IO VMState
setNewMaxSize state newSize' = do
  --TODO- I should just store the number of words....  memory size can only be a multiple of words.
  --For now I will just use this hack to allocate to the nearest higher number of words.
  let newSize = 32 * ceiling (fromIntegral newSize'/(32::Double))::Integer
  oldSize <- readIORef (mSize $ memory state)

  let gasCharge =
        if newSize > fromIntegral oldSize
        then fromInteger $ (ceiling $ fromIntegral newSize/(32::Double)) - (ceiling $ fromIntegral oldSize/(32::Double))
        else 0

  let oldLength = fromIntegral $ V.length (mVector $ memory state)

  if vmGasRemaining state < gasCharge
     then return state{vmGasRemaining=0, vmException=Just OutOfGasException}
    else do
    when (newSize > fromIntegral oldSize) $ do
      writeIORef (mSize $ memory state) (fromInteger newSize)
    state' <-
      if newSize > oldLength
      then do
        arr' <- V.grow (mVector $ memory state) $ fromIntegral $ 2*newSize
        forM_ [oldLength..2*newSize-1] $ \p -> V.write arr' (fromIntegral p) 0
        return $ state{memory=(memory state){mVector = arr'}}
      else return state

    return state'{vmGasRemaining=vmGasRemaining state' - gasCharge}

getShow::Memory->IO String
getShow (Memory arr sizeRef) = do
  msize <- readIORef sizeRef
  --fmap (show . B16.encode . B.pack) $ sequence $ V.read arr <$> fromIntegral <$> [0..fromIntegral msize-1] 
  fmap (show . B16.encode . B.pack) $ sequence $ safeRead arr <$> [0..fromIntegral msize-1] 

getMemAsByteString::Memory->IO B.ByteString
getMemAsByteString (Memory arr sizeRef) = do
  msize <- readIORef sizeRef
  fmap B.pack $ sequence $ safeRead arr <$> [0..fromIntegral msize-1] 

mLoad::VMState->Word256->IO (VMState, [Word8])
mLoad state p = do
  state' <- setNewMaxSize state (fromIntegral p+32)
  val <- sequence $ safeRead (mVector $ memory state') <$> safeRange p 32
  return (state', val)

mLoad8::VMState->Word256->IO Word8
mLoad8 state p = do
  --setNewMaxSize m p
  safeRead (mVector $ memory state) (fromIntegral p)

mLoadByteString::VMState->Word256->Word256->IO (VMState, B.ByteString)
mLoadByteString state p 0 = return (state, B.empty) --no need to charge for mem change if nothing returned
mLoadByteString state p size = do
  state' <- setNewMaxSize state (fromIntegral p+fromIntegral size)
  if not . hasException $ state'
    then do
    val <- fmap B.pack $ sequence $ safeRead (mVector $ memory state) <$> fromIntegral <$> safeRange p size 
    return (state', val)
    else return (state', B.empty)

mStore::VMState->Word256->Word256->IO VMState
mStore state p val = do
  state' <- setNewMaxSize state (fromIntegral p+32)
  when (not . hasException $ state') $ 
                       sequence_ $ uncurry (V.write $ mVector $ memory state') <$> zip [fromIntegral p..] (word256ToBytes val)
  return state'

mStore8::VMState->Word256->Word8->IO VMState
mStore8 state p val = do
  state' <- setNewMaxSize state (fromIntegral p+1)
  when (not . hasException $ state') $ V.write (mVector $ memory state') (fromIntegral p) val
  return state'

mStoreByteString::VMState->Word256->B.ByteString->IO VMState
mStoreByteString state p theData = do
  state' <- setNewMaxSize state (fromIntegral p + fromIntegral (B.length theData))
  when (not . hasException $ state') $ 
    sequence_ $ uncurry (V.write $ mVector $ memory state') <$> zip (fromIntegral <$> safeRange p (fromIntegral $ B.length theData)) (B.unpack theData)
  return state'

