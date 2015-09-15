module Utils.Vector
 ( zeroVec
 , toFractions
 , unsafeIncrement
 , unsafeIncrement'
 , unsafeModify
 ) where

import Control.Monad
import Control.Monad.Primitive
import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Unboxed.Mutable as VM


zeroVec n = VM.replicate n (0 :: Int)

unsafeIncrement :: (Num a, PrimMonad m, VM.Unbox a) => VM.MVector (PrimState m) a -> Int -> m ()
unsafeIncrement v i = unsafeIncrement' v i 1

unsafeIncrement' :: (Num a, PrimMonad m, VM.Unbox a) => VM.MVector (PrimState m) a -> Int -> a -> m ()
unsafeIncrement' v i inc = unsafeModify v (+ inc) i

unsafeModify :: (PrimMonad m, VM.Unbox a) => VM.MVector (PrimState m) a -> (a -> a) -> Int -> m ()
unsafeModify v f i = do
    c <- VM.unsafeRead v i
    VM.unsafeWrite v i (f c)


toFractions v = do
    v' <- V.unsafeFreeze v
    let total = V.foldr1 (+) v'
        n = VM.length v
    forM_ [0..n - 1] $ \i ->
        unsafeModify v (/ total) i
