{-# OPTIONS_JHC -fno-prelude -fffi #-}

-- just a few basic operations on integers to jumpstart things
module Jhc.Int(Int(),Int_(),increment,decrement,plus,minus,times,divide,modulus,zero,one,boxInt,unboxInt) where

import Jhc.Type.Word(Int(),Int_())

foreign import primitive increment :: Int -> Int
foreign import primitive decrement :: Int -> Int
foreign import primitive "Add" plus      :: Int -> Int -> Int
foreign import primitive "Sub" minus     :: Int -> Int -> Int
foreign import primitive "Mul" times     :: Int -> Int -> Int
foreign import primitive "Div" divide    :: Int -> Int -> Int
foreign import primitive "Mod" modulus   :: Int -> Int -> Int
foreign import primitive zero      :: Int
foreign import primitive one       :: Int

foreign import primitive "box" boxInt :: Int_ -> Int
foreign import primitive "unbox" unboxInt :: Int -> Int_
