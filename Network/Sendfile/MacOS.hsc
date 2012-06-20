{-# LANGUAGE CPP, ForeignFunctionInterface #-}

module Network.Sendfile.MacOS (
    sendfile
  , sendfileWithHeader
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import Data.Int
import Foreign.C.Error (eAGAIN, eINTR, getErrno, throwErrno)
#if __GLASGOW_HASKELL__ >= 703
import Foreign.C.Types (CInt(CInt))
#else
import Foreign.C.Types (CInt)
#endif
import Foreign.Marshal (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)
import Network.Sendfile.Types
import Network.Socket
import Network.Socket.ByteString
import System.Posix.IO
import System.Posix.Types (Fd(..))

#include <sys/types.h>

{-|
   Simple binding for sendfile() of MacOS.

   - Used system calls: open(), sendfile(), and close().

   The fourth action argument is called when a file is sent as chunks.
   Chucking is inevitable if the socket is non-blocking (this is the
   default) and the file is large. The action is called after a chunk
   is sent and bofore waiting the socket to be ready for writing.
-}
sendfile :: Socket -> FilePath -> FileRange -> IO () -> IO ()
sendfile sock path range hook = bracket
    (openFd path ReadOnly Nothing defaultFileFlags)
    closeFd
    sendfile'
  where
    dst = Fd $ fdSocket sock
    sendfile' fd = alloca $ \lenp -> case range of
        EntireFile -> do
            poke lenp 0
            sendloop dst fd 0 lenp hook
        PartOfFile off len -> do
            let off' = fromInteger off
            poke lenp (fromInteger len)
            sendloop dst fd off' lenp hook

sendloop :: Fd -> Fd -> (#type off_t) -> Ptr (#type off_t) -> IO () -> IO ()
sendloop dst src off lenp hook = do
    len <- peek lenp
    rc <- c_sendfile src dst off lenp
    when (rc /= 0) $ do
        errno <- getErrno
        if errno `elem` [eAGAIN, eINTR] then do
            sent <- peek lenp
            if len == 0 then
                poke lenp 0 -- Entire
              else
                poke lenp (len - sent)
            hook
            threadWaitWrite dst
            sendloop dst src (off + sent) lenp hook
          else
            throwErrno "Network.SendFile.MacOS.sendloop"

c_sendfile :: Fd -> Fd -> (#type off_t) -> Ptr (#type off_t) -> IO CInt
c_sendfile fd s offset lenp = c_sendfile' fd s offset lenp nullPtr 0

foreign import ccall unsafe "sys/uio.h sendfile" c_sendfile'
    :: Fd -> Fd -> (#type off_t) -> Ptr (#type off_t) -> Ptr () -> CInt -> IO CInt

sendfileWithHeader :: Socket -> FilePath -> FileRange -> IO () -> [ByteString] -> IO ()
sendfileWithHeader sock path range hook headers = bracket
    (openFd path ReadOnly Nothing defaultFileFlags)
    closeFd
    sendfile'
  where
    dst = Fd $ fdSocket sock
    sendfile' fd = do
        sendMany sock headers
        alloca $ \lenp -> case range of
            EntireFile -> do
                poke lenp 0
                sendloop dst fd 0 lenp hook
            PartOfFile off len -> do
                let off' = fromInteger off
                poke lenp (fromInteger len)
                sendloop dst fd off' lenp hook
