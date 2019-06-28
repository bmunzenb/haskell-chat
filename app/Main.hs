{-# LANGUAGE LambdaCase, OverloadedStrings #-}
{-# OPTIONS_GHC -Wall -Werror -Wno-type-defaults #-}

{-
TODO:
Presently all the code is here, in this file. We need to properly organize the code into modules.
This file can be the only file in the "app" directory.
Under "src", there will be a number of distinct files/modules:
* One module should contain all our data type declarations and type aliases. Doing this helps to avoid circular imports in large apps.
* Other modules can be created based on theme. For example, one module might contain "Text" utility functions.
* You'll probably want to put "threadServer" and the functions it calls ("interp") in a single module.
Modules should only export the functions that other modules need.
-}

module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.Async (Async, AsyncCancelled(..), async, cancel, wait)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (TQueue, newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (Exception, SomeException, fromException)
import Control.Exception.Lifted (finally, handle, throwIO, throwTo)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.Bool (bool)
import Data.IntMap (IntMap)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List ((\\))
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import GHC.Stack (HasCallStack, callStack, prettyCallStack)
import Network.Socket (socketToHandle)
import Network.Simple.TCP (HostPreference(HostAny), ServiceName, accept, listen)
import System.IO (BufferMode(LineBuffering), Handle, Newline(CRLF), NewlineMode(NewlineMode, inputNL, outputNL), IOMode(ReadWriteMode), hClose, hFlush, hIsEOF, hSetBuffering, hSetEncoding, hSetNewlineMode, latin1)
import qualified Data.IntMap as M
import qualified Data.Text as T
import qualified Data.Text.IO as T (hGetLine, hPutStr, putStrLn)

{-
To connect:
brew install telnet
telnet localhost 9696
-}

{-
Keep in mind that in Haskell, killing a parent thread does NOT kill its children threads!
Threads must be manually managed via the "Async" library. This takes careful thought and consideration.
Threads should never be "leaked:" we don't ever want a situation in which a child thread is left running and no other threads are aware of it.
Of course, the app should be architected in such a way that when an exception is thrown, it is handled gracefully. First and foremost, an exception must be caught on/by the thread on which the exception was thrown. If the exception represents something critical or unexpected (it's a bug, etc. - this is the vast majority of exceptions that we'll encounter in practice), and the exception occurs on a child thread, then the child thread should rethrow the exception to the listen (main) thread. The listen thread's exception handler should catch the rethrown exception and gracefully shut down, manually killing all child threads in the process.
-}

type ChatStack = ReaderT Env IO
type Env       = IORef ChatState
type MsgQueue  = TQueue Msg
type UserID    = Int

data ChatState = ChatState { listenThreadId :: Maybe ThreadId, msgQueues :: IntMap MsgQueue, talkThreadAsyncs :: IntMap (Async ())}

data Msg = FromClient Text
         | FromServer Text
         | Dropped

data PleaseDie = PleaseDie deriving (Show, Typeable)
instance Exception PleaseDie

initChatState :: ChatState
initChatState = ChatState Nothing M.empty M.empty

main :: HasCallStack => IO ()
main = runReaderT threadListen =<< newIORef initChatState

-- This is the main thread. It listens for incoming connections.
threadListen :: HasCallStack => ChatStack ()
threadListen = liftIO myThreadId >>= \ti -> do
    modifyState $ \cs -> (cs { listenThreadId = Just ti }, ())
    liftIO . T.putStrLn $ "Welcome to the Haskell Chat Server!"
    listenHelper `finally` bye
  where
    bye = liftIO . T.putStrLn . nl $ "Goodbye!"

listenHelper :: HasCallStack => ChatStack ()
listenHelper = handle listenExHandler $ ask >>= \env ->
    let listener = liftIO . listen HostAny port $ accepter
        accepter (serverSocket, _) = forever . accept serverSocket $ talker
        talker (clientSocket, remoteAddr) = do
            T.putStrLn . T.concat $ [ "Connected to ", showTxt remoteAddr, "." ]
            h <- socketToHandle clientSocket ReadWriteMode
            runReaderT (startTalk h) env
    in listener

startTalk :: HasCallStack => Handle -> ChatStack ()
startTalk h = do
  mq <- liftIO newTQueueIO
  uid <- modifyState $ \cs -> let mqs = msgQueues cs
                                  uid = head $ [0..] \\ M.keys mqs
                              in (cs { msgQueues = M.insert uid mq mqs }, uid)
  a <- runAsync . threadTalk uid h $ mq
  modifyState $ \cs -> let as = talkThreadAsyncs cs
                       in (cs { talkThreadAsyncs = M.insert uid a as }, ())
  sendToAllOtherUsers uid $ "User " <> showTxt uid <> " connected."

listenExHandler :: HasCallStack => SomeException -> ChatStack ()
listenExHandler e = getState >>= \cs -> do
    mapM_ (`writeMsg` Dropped) . M.elems . msgQueues $ cs
    mapM_ (liftIO . wait) . M.elems . talkThreadAsyncs $ cs
    throwIO e

-- This thread is spawned for every incoming connection.
-- Its main responsibility is to spawn a "receive" and a "server" thread.
threadTalk :: HasCallStack => UserID -> Handle -> MsgQueue -> ChatStack ()
threadTalk uid h mq = talk `finally` cleanUp
  where
    talk = do
        liftIO configBuffer
        (recvThread, serverThread) <- (,) <$> runAsync (threadReceive h mq) <*> runAsync (threadServer uid h mq)
        liftIO $ wait serverThread >> cancel recvThread
    configBuffer = hSetBuffering h LineBuffering >> hSetNewlineMode h nlMode >> hSetEncoding h latin1
    nlMode       = NewlineMode { inputNL = CRLF, outputNL = CRLF }
    cleanUp      = do
        modifyState $ \cs -> let mqs = msgQueues cs
                                 tas = talkThreadAsyncs cs
                             in (cs { msgQueues = M.delete uid mqs, talkThreadAsyncs = M.delete uid tas }, ())
        liftIO . hClose $ h
        sendToAllOtherUsers uid $ "User " <> showTxt uid <> " disconnected."
        

-- This thread polls the handle for the client's connection. Incoming text is sent down the message queue.
threadReceive :: HasCallStack => Handle -> MsgQueue -> ChatStack ()
threadReceive h mq = handle receiveExHandler . mIf (liftIO . hIsEOF $ h) (writeMsg mq Dropped) $ do
    receive mq =<< liftIO (T.hGetLine h)
    threadReceive h mq

receiveExHandler :: HasCallStack => SomeException -> ChatStack ()
receiveExHandler e = case fromException e of
  Just AsyncCancelled -> return ()
  _                   -> throwToListenThread e

{-
This thread polls the client's message queue and processes everything that comes down the queue.
It is named "threadServer" because this is where the bulk of server operations and logic reside.
But keep in mind that this function is executed for every client, and thus the code we write here is written from the standpoint of a single client (ie, the arguments to this function are the handle and message queue of a single client).
(Of course, we are in the "ChatStack" so we have access to the global shared state.)
-}
threadServer :: HasCallStack => UserID -> Handle -> MsgQueue -> ChatStack ()
threadServer uid h mq = handle throwToListenThread $ readMsg mq >>= let loop = (>> threadServer uid h mq) in \case
  FromClient txt -> loop . interp uid mq $ txt
  FromServer txt -> loop . liftIO $ T.hPutStr h txt >> hFlush h
  Dropped        -> return () -- This kills the crab.

interp :: HasCallStack => UserID -> MsgQueue -> Text -> ChatStack ()
interp uid mq txt = case T.toLower txt of
  "/quit"  -> send mq "See you next time!" >> writeMsg mq Dropped
  "/throw" -> throwIO PleaseDie -- For illustration/testing.
  "/users" -> usersCommand mq
  _        -> sendToAllOtherUsers uid txt

{-
The Haskell language, software transactional memory, and this app are all architected in such a way that we need not concern ourselves with the usual pitfalls of sharing state across threads. This automatically rules out a whole class of potential bugs! Just remember the following:
1) If you are coding an operation that simply needs to read the state, use the "getState" helper function.
2) If you are coding an operation that needs to update the state, you must bundle the operation into an atomic unit: that is, a single function passed into the "modifyState" helper function. (The function passed to "modifyState" is itself passed the latest state.)
It's ensured that only one thread can modify the state (via "modifyState") at a time.
-}
getState :: HasCallStack => ChatStack ChatState
getState = liftIO . readIORef =<< ask

modifyState :: HasCallStack => (ChatState -> (ChatState, a)) -> ChatStack a
modifyState f = ask >>= \ref -> liftIO . atomicModifyIORef' ref $ f

readMsg :: HasCallStack => MsgQueue -> ChatStack Msg
readMsg = liftIO . atomically . readTQueue

writeMsg :: HasCallStack => MsgQueue -> Msg -> ChatStack ()
writeMsg mq = liftIO . atomically . writeTQueue mq

send :: HasCallStack => MsgQueue -> Text -> ChatStack ()
send mq = writeMsg mq . FromServer . nl

receive :: HasCallStack => MsgQueue -> Text -> ChatStack ()
receive mq = writeMsg mq . FromClient

-- Spawn a new thread in the "ChatStack".
runAsync :: HasCallStack => ChatStack () -> ChatStack (Async ())
runAsync f = liftIO . async . runReaderT f =<< ask

{-
Note that we don't use the "Async" library here because the listen thread is the main thread: we didn't start it ourselves via the "async" function, and we have no "Async" data for it.
When you do have an "Async" object, you can use the "asyncThreadId" function to get the thread ID for the "Async".
-}
throwToListenThread :: HasCallStack => SomeException -> ChatStack ()
throwToListenThread e = do
    maybeVoid (`throwTo` e) . listenThreadId =<< getState
    liftIO . T.putStrLn . T.pack . prettyCallStack $ callStack

--------------------
-- Misc. bindings and utility functions

port :: ServiceName
port = "9696"

-- Monadic "if".
mIf :: (HasCallStack, Monad m) => m Bool -> m a -> m a -> m a
mIf p x = (p >>=) . flip bool x

-- Operate on a "Maybe" in a monad. Do nothing on "Nothing".
maybeVoid :: (HasCallStack, Monad m) => (a -> m ()) -> Maybe a -> m ()
maybeVoid = maybe (return ())

nl :: Text -> Text
nl = (<> nlTxt)

nlTxt :: Text
nlTxt = T.singleton '\n'

--dblQuote :: Text -> Text
--dblQuote txt = let a = T.singleton '"' in a <> txt <> a

showTxt :: (Show a) => a -> Text
showTxt = T.pack . show

-- Commands
usersCommand :: HasCallStack => MsgQueue -> ChatStack ()
usersCommand mq = send mq . T.intercalate nlTxt . map showTxt =<< allUserIDs

-- Helpers
allUserIDs :: HasCallStack => ChatStack [UserID]
allUserIDs = M.keys . msgQueues <$> getState

sendToAllOtherUsers :: HasCallStack => UserID -> Text -> ChatStack ()
sendToAllOtherUsers uid txt = mapM_ (`send` txt) . M.elems . M.delete uid . msgQueues =<< getState
