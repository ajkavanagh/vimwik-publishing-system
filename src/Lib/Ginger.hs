{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}

{-# OPTIONS_GHC -fplugin=Polysemy.Plugin #-}

module Lib.Ginger where

import           System.FilePath.Posix  (FilePath, isRelative, joinPath,
                                         makeRelative, normalise, pathSeparator,
                                         splitPath, takeDirectory, takeFileName,
                                         (<.>), (</>))

import qualified Data.ByteString.UTF8   as DBU
import           Data.Function          ((&))
import           Data.Maybe             (isNothing)
import           Data.Text              (Text)
import           Data.Text              as T

import           Colog.Core             (logStringStderr)
import           Colog.Polysemy         (Log, runLogAction)
import qualified Colog.Polysemy         as CP
import           Polysemy               (Embed, Member, Members, Sem, embed,
                                         embedToFinal, interpret, makeSem, run,
                                         runFinal)
import           Polysemy.Error         (Error)
import qualified Polysemy.Error         as PE
import           Polysemy.Reader        (Reader)
import qualified Polysemy.Reader        as PR
import           Polysemy.State         (State)
import qualified Polysemy.State         as PS
import           Polysemy.Writer        (Writer)
import qualified Polysemy.Writer        as PW

import           Text.Ginger            (GVal, IncludeResolver, Source,
                                         SourceName, SourcePos, Template,
                                         ToGVal)
import qualified Text.Ginger            as TG
import           Text.Ginger.Html       (Html, htmlSource)

import           Effect.File            (File, FileException)
import qualified Effect.File            as EF

import           Lib.Context.Core       (contextLookup)
import           Lib.Errors             (GingerException (..))
import           Lib.ResolvingTemplates (resolveTemplatePath)
import           Lib.SiteGenConfig      (SiteGenConfig (..))
import           Types.Context          (Context, RunSem, RunSemGVal)


parseToTemplate
    :: Members '[ File
                , Error FileException
                , Error GingerException
                , Reader SiteGenConfig
                , Log String
                ] r
    => SourceName
    -> Sem r (Template SourcePos)
parseToTemplate source = do
    res <- TG.parseGingerFile includeResolver source
    case res of
        Left parseError -> PE.throw $ GingerException (T.pack $ show parseError)
        Right tpl       -> pure tpl


includeResolver
    :: Members '[ File
                , Error FileException
                , Reader SiteGenConfig
                , Log String
                ] r
    => IncludeResolver (Sem r)
includeResolver source = do
    CP.log @String $ "includeResolver: trying to resolve :" <> show source
    -- try using the filepath we were sent
    sgc <- PR.ask @SiteGenConfig
    let tDir = sgcTemplatesDir sgc
        tExt = sgcTemplateExt sgc
    mFp <- resolveTemplatePath tDir source >>= (\case
        -- if we got nothing back, try to resolve it with an extension added
        Nothing -> resolveTemplatePath tDir (source <.> tExt)
        fp@(Just _) -> pure fp)
    case mFp of
        Just fp -> Just . DBU.toString <$> EF.readFile fp Nothing Nothing
        Nothing -> PE.throw $ EF.FileException source "File Not found"


-- | Render a template using a context and a parsed Ginger template.  Note the
-- extra (Writer Text : ...) bit -- this is necessary as we want to run
-- PW.runWrirunWriterAssocR @Text in the body, and thus need to add that to the
-- 'r' bit as the @Context m@, but not @Sem r@ that comes into the function.
renderTemplate
    :: ( Member (Error GingerException) r
       , Member (Log String) r
       )
    => Context (RunSem (Writer Text : r))
    -> Template TG.SourcePos
    -> Sem r Text
renderTemplate ctxt tpl = do
    res <- PW.runWriterAssocR @Text $ renderTemplate' ctxt tpl
    pure $ fst res


renderTemplate'
    :: ( Member (Writer Text) r
       , Member (Error GingerException) r
       , Member (Log String) r
       )
    => Context (RunSem r)
    -> Template TG.SourcePos
    -> Sem r ()
renderTemplate' ctxt tpl = do
    let context = TG.makeContextHtmlM (contextLookup ctxt) drainHtml
    res <- TG.runGingerT context tpl
    case res of
        Left err -> PE.throw $ GingerException (T.pack $ show err)
        Right _  -> pure ()


-- get the html out (as text) -- we'll later push this to conduitT and write it
-- into a file
drainHtml
    :: Member (Writer Text) r
    => Html
    -> Sem r ()
drainHtml html = PW.tell $ htmlSource html