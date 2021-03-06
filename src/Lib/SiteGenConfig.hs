{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
--{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Lib.SiteGenConfig where

import           TextShow

import           System.FilePath (FilePath, makeRelative, pathSeparator,
                                  takeDirectory, (</>), normalise)

import           Control.Monad   (forM, when)

import           Data.List       (intercalate)
import           Data.Maybe      (catMaybes, fromJust, isNothing)
import           Data.Text       (Text)
import qualified Data.Text       as T
import           Data.Yaml       ((.!=), (.:), (.:?))
import qualified Data.Yaml       as Y

import qualified Network.URI     as NU

-- For Polysemy logging of things going on.
import           Colog.Polysemy  (Log)
import qualified Colog.Polysemy  as CP
import           Polysemy        (Embed, Members, Sem, embed)
import           Polysemy.Error  (Error, throw)

import           Effect.File     (File, FileException)
import qualified Effect.File     as EF
import           Effect.Logging  (LoggingMessage)
import qualified Effect.Logging  as EL


-- | define the biggest file we are willing to process
maxFileToProcessSize :: Int
maxFileToProcessSize = 100 * 1024


data ConfigException = ConfigException Text
                     | ConfigExceptions [ConfigException]

instance Show ConfigException where
    show ex = "Config Loading failed due to: " ++ ss
      where
          ss = case ex of
              (ConfigException s)   -> show s
              (ConfigExceptions xs) -> intercalate ", " $ map show xs

{-
site: <site-identifier>
source: ./src  # the directory (relative, if wanted, to the site.yaml) to start
               # looking for sitegen pages.
output-dir: ./html
extension: .md # the extension of files that may be sitegen page parts
index-page-name: index # string representing the custom page name for the index
templates-dir: ./templates # directory to find templates
template-ext: .html  # the extension used for templates
css-dir: ./templates/css  # directory to find css files.
default-style: style.css  # name of the default style sheet.
generate-tags: true  # should sitegen generate a tags page
generate-categories: true  # should sitegen generate categories
-}

data RawSiteGenConfig = RawSiteGenConfig
    { _siteId             :: !String
    , _siteUrl            :: !(Maybe String)
    , _vimwikiDir         :: !FilePath
    , _source             :: !FilePath
    , _outputDir          :: !FilePath
    , _extension          :: !String
    , _indexPageName      :: !String
    , _themeDir           :: !FilePath
    , _templateDirs       :: ![FilePath]
    , _templateExt        :: !String
    , _outputFileExt      :: !String
    , _staticDirs         :: ![FilePath]
    , _copyStaticFiles    :: !Bool
    , _generateTags       :: !Bool
    , _generateCategories :: !Bool
    , _generateFeed       :: !Bool
    , _publishDrafts      :: !Bool
    , _indexFiles         :: !Bool
    , _maxSummaryWords    :: !Int
    , _skylightStyle      :: !(Maybe Text)
    , _params             :: !(Maybe Y.Object)
    } deriving (Show)


instance Y.FromJSON RawSiteGenConfig where
    parseJSON (Y.Object v) = RawSiteGenConfig
        <$> v .:? "site"                .!= "default"          -- site: <site-identifier>
        <*> v .:? "siteURL"                                    -- http(s)://some.domain/
        <*> v .:? "vimwiki-dir"         .!= "."                 -- optionally the directory relative to the site.yaml for the vimwiki root
        <*> v .:? "source"              .!= "./src"            -- the directory (relative to the site.yaml) to start
        <*> v .:? "output-dir"          .!= "./html"           -- where to place output files
        <*> v .:? "extension"           .!= ".md"              -- the extension for source files
        <*> v .:? "index-page-name"     .!= "index"            -- The 'start' page for the site.
        <*> v .:? "theme-dir"           .!= "./theme"          -- directory to find the theme
        <*> v .:? "template-dirs"       .!= []                 -- overrides for templates
        <*> v .:? "template-ext"        .!= ".html.j2"         -- the extension used for templates
        <*> v .:? "output-file-ext"     .!= ".html"            -- the extension used for the output files
        <*> v .:? "statics-dirs"        .!= []                 -- where the static files currently live
        <*> v .:? "copy-static-files"   .!= True               -- By default we do copy static files as that should be normal
        <*> v .:? "generate-tags"       .!= False              -- should sitegen generate a tags page
        <*> v .:? "generate-categories" .!= False              -- should sitegen generate categories
        <*> v .:? "generate-feed"       .!= False              -- should sitegen genrate an atom feed page?
        <*> v .:? "publish-drafts"      .!= False              -- should we publish drafs?
        <*> v .:? "index-files"         .!= True               -- should index files be generated?
        <*> v .:? "max-summary-words"   .!= 70                 -- Number of words to grab for summary
        <*> v .:? "skylight-style"                             -- the style to use for highlighting (or Not)
        <*> v .:? "params"                                     -- grab any defined parameters
    parseJSON _ = error "Can't parse SitegenConfig from YAML/JSON"


readConfig
    :: Members '[ File
                , Error FileException
                , Error ConfigException
                ] r
    => FilePath
    -> Sem r RawSiteGenConfig
readConfig fp = do
    bs <- EF.readFile fp Nothing Nothing
    case Y.decodeEither' bs of
        Left parseException -> throw $ ConfigException $ T.pack $ show parseException
        Right conf          -> pure conf


data SiteGenConfig = SiteGenConfig
    { sgcSiteYaml           :: !FilePath
    , sgcSiteUrl            :: !(Maybe NU.URI)
    , sgcSiteId             :: !String
    , sgcRoot               :: !FilePath
    , sgcVimWikiRoot        :: !FilePath
    , sgcSourceRelDir       :: !FilePath
    , sgcSource             :: !FilePath
    , sgcOutputDir          :: !FilePath
    , sgcExtension          :: !String
    , sgcIndexPageName      :: !String
    , sgcThemeDir           :: !FilePath
    , sgcTemplatesDirs      :: ![FilePath]
    , sgcTemplateExt        :: !String
    , sgcOutputFileExt      :: !String
    , sgcStaticDirs         :: ![FilePath]
    , sgcCopyStaticFiles    :: !Bool
    , sgcGenerateTags       :: !Bool
    , sgcGenerateCategories :: !Bool
    , sgcGenerateFeed       :: !Bool
    , sgcPublishDrafts      :: !Bool
    , sgcIndexFiles         :: !Bool
    , sgcMaxSummaryWords    :: !Int
    , sgcSkylightStyle      :: !(Maybe Text)
    , sgcExtraDebug         :: !Bool
    , sgcParams             :: !(Maybe Y.Object)
    } deriving (Show)


getSiteGenConfig
    :: Members '[ Log LoggingMessage
                , File
                , Error FileException
                , Error ConfigException
                ] r
    => FilePath
    -> Bool
    -> Bool
    -> Sem r SiteGenConfig
getSiteGenConfig configFileName forceDrafts extraDebug = do
    configPath <- EF.makeAbsolute configFileName
    rawConfig <- readConfig configPath
    makeSiteGenConfigFromRaw configPath rawConfig forceDrafts extraDebug


makeSiteGenConfigFromRaw
    :: Members '[ Log LoggingMessage
                , File
                , Error FileException
                , Error ConfigException
                ] r
    => FilePath
    -> RawSiteGenConfig
    -> Bool
    -> Bool
    -> Sem r SiteGenConfig
makeSiteGenConfigFromRaw configPath rawConfig forceDrafts extraDebug = do
    let root = takeDirectory configPath
    source_ <- resolvePath (_source rawConfig) root "source dir"
    outputDir_ <- resolvePath (_outputDir rawConfig) root "output dir"
    themeDir_ <- resolvePath (_themeDir rawConfig) root "theme dir"
    themeTemplatesDir_ <- resolvePath (_themeDir rawConfig </> "templates") root "theme templates dir"
    -- note this one is optional, although it produces an logError if it doesn't
    -- exist
    templatesStaticDir_ <- resolvePath (_themeDir rawConfig </> "static") root "theme static dir"
    staticDirs_ <- forM (_staticDirs rawConfig) $ \_dir ->
        resolvePath _dir root ("statics dir: " ++ _dir)
    templatesDirs_ <- forM (_templateDirs rawConfig) $ \_dir ->
        resolvePath _dir root ("templates dir: " ++ _dir)
    vimwikiDir_ <- resolvePath (_vimwikiDir rawConfig) root "vimwikiRoot dir"
    -- now ensure that source_ is a subdir of vimwikiDir_ -- if it's not then we
    -- need to error out.
    let sourceRelDir_ = makeRelativeMaybe vimwikiDir_ source_
    when (isNothing sourceRelDir_)
        $ throw $ ConfigException $ T.pack $ "vimwikidir: "
                                          <> show vimwikiDir_
                                          <> " is not a parent of source: "
                                          <> show source_
    if any isNothing ([ source_
                      , outputDir_
                      , themeDir_
                      , themeTemplatesDir_
                      , vimwikiDir_
                      , sourceRelDir_] ++ staticDirs_ ++ templatesDirs_)
      then throw $ ConfigException "One or more directories didn't exist"
      else pure SiteGenConfig
          { sgcSiteYaml=configPath
          , sgcSiteUrl=fixNullPath <$> (NU.parseAbsoluteURI =<< _siteUrl rawConfig)
          , sgcSiteId=_siteId rawConfig
          , sgcRoot=root
          , sgcVimWikiRoot=fromJust vimwikiDir_
          , sgcSourceRelDir=fromJust sourceRelDir_
          , sgcSource=fromJust source_
          , sgcOutputDir=fromJust outputDir_
          , sgcExtension=_extension rawConfig
          , sgcIndexPageName=_indexPageName rawConfig
          , sgcThemeDir=fromJust themeDir_
          , sgcTemplatesDirs=catMaybes (templatesDirs_ ++ [themeTemplatesDir_])
          , sgcTemplateExt=_templateExt rawConfig
          , sgcOutputFileExt=_outputFileExt rawConfig
          , sgcStaticDirs=catMaybes (templatesStaticDir_ : staticDirs_)
          , sgcCopyStaticFiles=_copyStaticFiles rawConfig
          , sgcGenerateTags=_generateTags rawConfig
          , sgcGenerateCategories=_generateCategories rawConfig
          , sgcGenerateFeed=_generateFeed rawConfig
          , sgcPublishDrafts=_publishDrafts rawConfig || forceDrafts
          , sgcIndexFiles=_indexFiles rawConfig
          , sgcMaxSummaryWords=_maxSummaryWords rawConfig
          , sgcSkylightStyle=_skylightStyle rawConfig
          , sgcExtraDebug=extraDebug
          , sgcParams=_params rawConfig
          }


fixNullPath :: NU.URI -> NU.URI
fixNullPath nu =
    let path = NU.uriPath nu
     in if null path
          then nu { NU.uriPath="/" }
          else nu


resolvePath
    :: Members '[ Log LoggingMessage
                , File
                , Error FileException
                ] r
    => FilePath        -- The path to resolve
    -> FilePath        -- the root to perhaps prepend to it.
    -> String          -- A handy error string to log with (maybe)
    -> Sem r (Maybe FilePath)  -- what to return
resolvePath "" _ errorStr = do
    EL.logError$ T.pack $ "Path  is empty for: " ++ errorStr
    pure Nothing
resolvePath path root errorStr = do
    resolvedPath <- if head path /= pathSeparator
                      then EF.canonicalizePath (root </> path)
                      else EF.canonicalizePath path
    exists <- EF.doesDirectoryExist resolvedPath
    if exists
      then pure $ Just resolvedPath
      else do
          EL.logError $ T.pack $ "Path " ++ resolvedPath ++ " doesn't exist for: " ++ errorStr
          pure Nothing


-- | return the relative path of root being a parent dir of child.  If it is not
-- then return Nothing. Note the relative bit needs to be "rooted" (i.e. start
-- with a '/') so that it can be matched with roots in links.
makeRelativeMaybe :: Maybe FilePath -> Maybe FilePath -> Maybe FilePath
makeRelativeMaybe Nothing _ = Nothing
makeRelativeMaybe _ Nothing = Nothing
makeRelativeMaybe (Just root) (Just child) =
    let relative = makeRelative root child
     in if relative == child
      then Nothing
      else Just ("/" <> relative)


-- | Modify the directory for printing; returns a string
dirForPrint :: (SiteGenConfig -> FilePath) -> SiteGenConfig -> String
dirForPrint f sgc =
    let root = sgcRoot sgc
        path = f sgc
        p1 = makeRelative root path
     in if length p1 < length path then "<root>/" <> p1 else path


dirForPrint' :: FilePath -> SiteGenConfig -> String
dirForPrint' fp sgc =
    let root = sgcRoot sgc
        p1 = makeRelative root fp
     in if length p1 < length fp then "<root>/" <> p1 else fp
