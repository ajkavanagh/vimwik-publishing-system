{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}



module Effect.File
      where

import           Prelude            hiding (readFile)

import           System.FilePath    (takeExtension)
import           System.IO          (IOMode (ReadMode), SeekMode (AbsoluteSeek),
                                     hClose, hSeek, openBinaryFile)
import           System.IO.Error    (tryIOError)
import qualified System.Posix.Files as SPF

import           Control.Exception  (bracket)
import           Control.Monad      (when)

import           Data.ByteString    (ByteString)
import qualified Data.ByteString    as BS
import           Data.Function      ((&))
import           Data.List          (intercalate)
import           Data.Maybe         (fromJust, isJust)

import           Conduit            (MonadResource, filterC, runConduit,
                                     runResourceT, sinkList,
                                     sourceDirectoryDeep, sourceDirectory)
import           Data.Conduit       (ConduitT, (.|))

import           Polysemy           (Embed, Member, Members, Sem, embed,
                                     embedToFinal, interpret, makeSem, run,
                                     runFinal)
import           Polysemy.Error     (Error)
import qualified Polysemy.Error     as PE
import           Polysemy.Output    (runOutputList)
import           Polysemy.Reader    (Reader, ask)

{-
   File effect to read and write files that can throw an error.  The main idea
   is that the code can read and write files and the errors that are thrown are
   Polysemy errors.
-}


data FileException = FileException String
                     | FileExceptions [FileException]

instance Show FileException where
    show ex = "File Handing issue: " ++ ss
      where
          ss = case ex of
              (FileException s)   -> s
              (FileExceptions xs) -> intercalate ", " $ map show xs


data File m a where
    FileStatus :: FilePath -> File m SPF.FileStatus
    ReadFile :: FilePath -> Maybe Int -> Maybe Int -> File m ByteString
    WriteFile :: FilePath -> ByteString -> File m ()
    SourceDirectoryFilter :: FilePath -> (FilePath -> Bool) -> File m [FilePath]
    SourceDirectoryDeepFilter :: Bool -> FilePath -> (FilePath -> Bool) -> File m [FilePath]

makeSem ''File


fileToIO
    :: Members '[ Error FileException
                , Embed IO
                ] r
    => Sem (File ': r) a
    -> Sem r a
fileToIO = interpret $ \case
    -- Get the FileStatus for a file
    -- fileStatus :: FilePath -> FileStatus
    FileStatus fp -> do
        fs' <- embed $ tryIOError $ SPF.getFileStatus fp
        case fs' of
            Right fs     -> pure fs
            Left ioerror -> PE.throw $ FileException $ show ioerror

    -- read a file with optional offset and optional size
    -- readFile :: FilePath -> Maybe Int -> Maybe Int -> ByteString
    ReadFile fp seek size -> do
        res' <- embed $ tryIOError $ bracket
            (openBinaryFile fp ReadMode)
            (hClose)
            (\handle -> do
                when (isJust seek) $ hSeek handle AbsoluteSeek (toInteger (fromJust seek))
                case size of
                    Just size' -> BS.hGet handle size'
                    Nothing    -> BS.hGetContents handle)
        case res' of
            Right res    -> pure res
            Left ioerror -> PE.throw $ FileException $ show ioerror

    -- write a ByteString to the filepath
    -- writeFile :: FilePath -> ByteString
    WriteFile fp bs -> do
        res' <- embed $ tryIOError $ BS.writeFile fp bs
        case res' of
            Right _      -> pure ()
            Left ioerror -> PE.throw $ FileException $ show ioerror

    -- The next two functions use conduit and return a list of files.
    -- Conduit is used as it's convenient to list the files without using up
    -- lots of filehandles, plus we can run the filter in the stream.

    -- Do a shallow traverse into the file system at FilePath point.
    -- It returns everything, files, directories, symlinks, etc.
    -- Could throw a FileException if things go wrong
    -- SourceDirectoryDeepFilter
    -- :: FilePath            - the directory to list files from
    -- -> (FilePath -> Bool)  - a filter to apply to each filepath
    -- -> File m [FilePath]   - and return a list of FilePath types
    SourceDirectoryFilter dir filterFunc -> do
        res <- embed
             $ tryIOError
             $ runResourceT
             $ runConduit
             $ sourceDirectory dir
                .| filterC filterFunc
                .| sinkList
        case res of
            Left ioerror -> PE.throw $ FileException (show ioerror)
            Right paths  -> pure paths

    -- Do a deep traverse into the file system at FilePath point.
    -- Could throw a FileException if things go wrong
    -- SourceDirectoryDeepFilter
    -- :: FilePath            - the directory to list files from
    -- -> Bool                - whether to follow symlinks (True = follow)
    -- -> (FilePath -> Bool)  - a filter to apply to each filepath
    -- -> File m [FilePath]   - and return a list of FilePath types

    SourceDirectoryDeepFilter flag dir filterFunc -> do
        res <- embed
             $ tryIOError
             $ runResourceT
             $ runConduit
             $ sourceDirectoryDeep flag dir
                .| filterC filterFunc
                .| sinkList
        case res of
            Left ioerror -> PE.throw $ FileException (show ioerror)
            Right paths  -> pure paths


-- let's do q quick tests -- we'll delete these once we have stuff going!

runTest x = x & fileToIO
              & PE.errorToIOFinal @FileException
              & embedToFinal @IO
              & runFinal


getStatus :: Member File r => FilePath -> Sem r SPF.FileStatus
getStatus fp = fileStatus fp


fetchContents :: Member File r => FilePath -> Sem r ByteString
fetchContents fp = readFile fp Nothing Nothing

getStatusP fp = getStatus fp & runTest

fetchContentsP fp = fetchContents fp & runTest