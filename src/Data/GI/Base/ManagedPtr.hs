{-# LANGUAGE FlexibleContexts, ScopedTypeVariables #-}
-- For HasCallStack compatibility
{-# LANGUAGE ImplicitParams, KindSignatures, ConstraintKinds #-}

-- | We wrap most objects in a "managed pointer", which is simply a
-- newtype for a 'ForeignPtr' of the appropriate type:
--
-- > newtype Foo = Foo (ForeignPtr Foo)
--
-- Notice that types of this form are instances of
-- 'ForeignPtrNewtype'. The newtype is useful in order to make the
-- newtype an instance of different typeclasses. The routines in this
-- module deal with the memory management of such managed pointers.

module Data.GI.Base.ManagedPtr
    (
    -- * Managed pointers
      withManagedPtr
    , maybeWithManagedPtr
    , withManagedPtrList
    , unsafeManagedPtrGetPtr
    , unsafeManagedPtrCastPtr
    , touchManagedPtr

    -- * Safe casting
    , castTo
    , unsafeCastTo

    -- * Wrappers
    , newObject
    , wrapObject
    , refObject
    , unrefObject
    , newBoxed
    , wrapBoxed
    , copyBoxed
    , copyBoxedPtr
    , freeBoxed
    , wrapPtr
    , newPtr
    , copyPtr
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad (when, void)

import Data.Coerce (coerce)

import Foreign (poke)
import Foreign.C (CInt(..))
import Foreign.Ptr (Ptr, FunPtr, castPtr, nullPtr)
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, newForeignPtrEnv,
                           touchForeignPtr, newForeignPtr_)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)

import Data.GI.Base.BasicTypes
import Data.GI.Base.Utils

#if MIN_VERSION_base(4,9,0)
import GHC.Stack (HasCallStack)
#elif MIN_VERSION_base(4,8,0)
import GHC.Stack (CallStack)
import GHC.Exts (Constraint)
type HasCallStack = ((?callStack :: CallStack) :: Constraint)
#else
import GHC.Exts (Constraint)
type HasCallStack = (() :: Constraint)
#endif

-- | Perform an IO action on the 'Ptr' inside a managed pointer.
withManagedPtr :: ForeignPtrNewtype a => a -> (Ptr a -> IO c) -> IO c
withManagedPtr managed action = do
  let ptr = unsafeManagedPtrGetPtr managed
  result <- action ptr
  touchManagedPtr managed
  return result

-- | Like `withManagedPtr`, but accepts a `Maybe` type. If the passed
-- value is `Nothing` the inner action will be executed with a
-- `nullPtr` argument.
maybeWithManagedPtr :: ForeignPtrNewtype a => Maybe a -> (Ptr a -> IO c) -> IO c
maybeWithManagedPtr Nothing action = action nullPtr
maybeWithManagedPtr (Just managed) action = do
  let ptr = unsafeManagedPtrGetPtr managed
  result <- action ptr
  touchManagedPtr managed
  return result

-- | Perform an IO action taking a list of 'Ptr' on a list of managed
-- pointers.
withManagedPtrList :: ForeignPtrNewtype a => [a] -> ([Ptr a] -> IO c) -> IO c
withManagedPtrList managedList action = do
  let ptrs = map unsafeManagedPtrGetPtr managedList
  result <- action ptrs
  mapM_ touchManagedPtr managedList
  return result

-- | Return the 'Ptr' in a given managed pointer. As the name says,
-- this is potentially unsafe: the given 'Ptr' may only be used
-- /before/ a call to 'touchManagedPtr'. This function is of most
-- interest to the autogenerated bindings, for hand-written code
-- 'withManagedPtr' is almost always a better choice.
unsafeManagedPtrGetPtr :: ForeignPtrNewtype a => a -> Ptr a
unsafeManagedPtrGetPtr = unsafeManagedPtrCastPtr

-- | Same as 'unsafeManagedPtrGetPtr', but is polymorphic on the
-- return type.
unsafeManagedPtrCastPtr :: forall a b. ForeignPtrNewtype a => a -> Ptr b
unsafeManagedPtrCastPtr x = let p = coerce x :: ForeignPtr ()
                            in castPtr (unsafeForeignPtrToPtr p)

-- | Ensure that the 'Ptr' in the given managed pointer is still alive
-- (i.e. it has not been garbage collected by the runtime) at the
-- point that this is called.
touchManagedPtr :: forall a. ForeignPtrNewtype a => a -> IO ()
touchManagedPtr x = let p = coerce x :: ForeignPtr ()
                     in touchForeignPtr p

-- Safe casting machinery
foreign import ccall unsafe "check_object_type"
    c_check_object_type :: Ptr o -> CGType -> CInt

-- | Cast to the given type, checking that the cast is valid. If it is
-- not, we return `Nothing`. Usage:
--
-- > maybeWidget <- castTo Widget label
castTo :: forall o o'. (GObject o, GObject o') =>
          (ForeignPtr o' -> o') -> o -> IO (Maybe o')
castTo constructor obj =
    withManagedPtr obj $ \objPtr -> do
      GType t <- gobjectType (undefined :: o')
      if c_check_object_type objPtr t /= 1
        then return Nothing
        else Just <$> newObject constructor objPtr

-- | Cast to the given type, assuming that the cast will succeed. This
-- function will call `error` if the cast is illegal.
unsafeCastTo :: forall o o'. (HasCallStack, GObject o, GObject o') =>
                (ForeignPtr o' -> o') -> o -> IO o'
unsafeCastTo constructor obj =
  withManagedPtr obj $ \objPtr -> do
    GType t <- gobjectType (undefined :: o')
    if c_check_object_type objPtr t /= 1
      then do
      srcType <- gobjectType obj >>= gtypeName
      destType <- gobjectType (undefined :: o') >>= gtypeName
      error $ "unsafeCastTo :: invalid conversion from " ++ srcType ++ " to "
        ++ destType ++ " requested."
      else newObject constructor objPtr

-- Reference counting for constructors
foreign import ccall "&dbg_g_object_unref"
    ptr_to_g_object_unref :: FunPtr (Ptr a -> IO ())

foreign import ccall "g_object_ref" g_object_ref ::
    Ptr a -> IO (Ptr a)

-- | Construct a Haskell wrapper for a 'GObject', increasing its
-- reference count.
newObject :: (GObject a, GObject b) => (ForeignPtr a -> a) -> Ptr b -> IO a
newObject constructor ptr = do
  void $ g_object_ref ptr
  fPtr <- newForeignPtr ptr_to_g_object_unref $ castPtr ptr
  return $! constructor fPtr

foreign import ccall "g_object_ref_sink" g_object_ref_sink ::
    Ptr a -> IO (Ptr a)

-- | Same as 'newObject', but we take ownership of the object. Newly
-- created 'GObject's are typically floating, so we use
-- <https://developer.gnome.org/gobject/stable/gobject-The-Base-Object-Type.html#g-object-ref-sink g_object_ref_sink>.

-- Notice that the
-- semantics here are a little bit subtle: some objects (such as
-- GtkWindow, see the code about "user_ref_count" in gtkwindow.c in
-- the gtk+ distribution) are created /without/ the floating flag,
-- since they own a reference to themselves. So, wrapping them is
-- really about adding a ref. If we add the ref, when Haskell drops
-- the last ref to the 'GObject' it will /g_object_unref/, and the
-- window will /g_object_unref/ itself upon destruction, so by the end
-- we don't leak memory. If we don't add the ref, there will be two
-- /g_object_unrefs/ acting on the object (one from Haskell and one from
-- the GtkWindow destroy) when the object is destroyed and the second
-- one will give a segfault.
--
-- This is the story for GInitiallyUnowned objects (e.g. anything that
-- is a descendant from GtkWidget). For objects that are not initially
-- floating (i.e. not descendents of GInitiallyUnowned) we simply take
-- control of the reference.
wrapObject :: forall a b. (GObject a, GObject b) =>
              (ForeignPtr a -> a) -> Ptr b -> IO a
wrapObject constructor ptr = do
  when (gobjectIsInitiallyUnowned (undefined :: a)) $
       void $ g_object_ref_sink ptr
  fPtr <- newForeignPtr ptr_to_g_object_unref $ castPtr ptr
  return $! constructor fPtr

-- | Increase the reference count of the given 'GObject'.
refObject :: (GObject a, GObject b) => a -> IO (Ptr b)
refObject obj = castPtr <$> withManagedPtr obj g_object_ref

foreign import ccall "g_object_unref" g_object_unref ::
    Ptr a -> IO ()

-- | Decrease the reference count of the given 'GObject'. The memory
-- associated with the object may be released if the reference count
-- reaches 0.
unrefObject :: GObject a => a -> IO ()
unrefObject obj = withManagedPtr obj g_object_unref

foreign import ccall "& boxed_free_helper" boxed_free_helper ::
    FunPtr (Ptr env -> Ptr a -> IO ())

foreign import ccall "g_boxed_copy" g_boxed_copy ::
    CGType -> Ptr a -> IO (Ptr a)

-- | Construct a Haskell wrapper for the given boxed object. We make a
-- copy of the object.
newBoxed :: forall a. BoxedObject a => (ForeignPtr a -> a) -> Ptr a -> IO a
newBoxed constructor ptr = do
  GType gtype <- boxedType (undefined :: a)
  env <- allocMem :: IO (Ptr CGType)   -- Will be freed by boxed_free_helper
  poke env gtype
  ptr' <- g_boxed_copy gtype ptr
  fPtr <- newForeignPtrEnv boxed_free_helper env ptr'
  return $! constructor fPtr

-- | Like 'newBoxed', but we do not make a copy (we "steal" the passed
-- object, so now it is managed by the Haskell runtime).
wrapBoxed :: forall a. BoxedObject a => (ForeignPtr a -> a) -> Ptr a -> IO a
wrapBoxed constructor ptr = do
  GType gtype <- boxedType (undefined :: a)
  env <- allocMem :: IO (Ptr CGType)   -- Will be freed by boxed_free_helper
  poke env gtype
  fPtr <- newForeignPtrEnv boxed_free_helper env ptr
  return $! constructor fPtr

-- | Make a copy of the given boxed object.
copyBoxed :: forall a. BoxedObject a => a -> IO (Ptr a)
copyBoxed boxed = withManagedPtr boxed copyBoxedPtr

-- | Like 'copyBoxed', but acting directly on a pointer, instead of a
-- managed pointer.
copyBoxedPtr :: forall a. BoxedObject a => Ptr a -> IO (Ptr a)
copyBoxedPtr ptr = do
  GType gtype <- boxedType (undefined :: a)
  g_boxed_copy gtype ptr

foreign import ccall "g_boxed_free" g_boxed_free ::
    CGType -> Ptr a -> IO ()

-- | Free the memory associated with a boxed object
freeBoxed :: forall a. BoxedObject a => a -> IO ()
freeBoxed boxed = do
  GType gtype <- boxedType (undefined :: a)
  let ptr = unsafeManagedPtrGetPtr boxed
  g_boxed_free gtype ptr
  touchManagedPtr boxed

-- | Wrap a pointer, taking ownership of it.
wrapPtr :: WrappedPtr a => (ForeignPtr a -> a) -> Ptr a -> IO a
wrapPtr constructor ptr = do
  fPtr <- case wrappedPtrFree of
            Nothing -> newForeignPtr_ ptr
            Just finalizer -> newForeignPtr finalizer ptr
  return $! constructor fPtr

-- | Wrap a pointer, making a copy of the data.
newPtr :: WrappedPtr a => (ForeignPtr a -> a) -> Ptr a -> IO a
newPtr constructor ptr = do
  ptr' <- wrappedPtrCopy ptr
  fPtr <- case wrappedPtrFree of
            Nothing -> newForeignPtr_ ptr
            Just finalizer -> newForeignPtr finalizer ptr'
  return $! constructor fPtr

-- | Make a copy of a wrapped pointer using @memcpy@ into a freshly
-- allocated memory region of the given size.
copyPtr :: WrappedPtr a => Int -> Ptr a -> IO (Ptr a)
copyPtr size ptr = do
  ptr' <- wrappedPtrCalloc
  memcpy ptr' ptr size
  return ptr'
