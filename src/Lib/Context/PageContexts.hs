{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ExtendedDefaultRules  #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-# LANGUAGE AllowAmbiguousTypes   #-}

{-# LANGUAGE ConstraintKinds       #-}

-- needed for the instance ToGVal m a instances that use the RunSem r monad
{-# LANGUAGE UndecidableInstances  #-}

{-# OPTIONS_GHC -fplugin=Polysemy.Plugin #-}


module Lib.Context.PageContexts where

import           Data.Default                (def)
import qualified Data.HashMap.Strict         as HashMap
import qualified Data.List                   as L
import           Data.Maybe                  (fromMaybe, mapMaybe)
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Time.Clock             (UTCTime)
import           Data.Time.LocalTime         (LocalTime, utc, utcToLocalTime)

import           Colog.Polysemy              (Log)
import qualified Colog.Polysemy              as CP
import           Polysemy                    (Member, Sem)
import           Polysemy.Error              (Error)
import           Polysemy.Reader             (Reader)
import qualified Polysemy.Reader             as PR
import           Polysemy.State              (State)
import qualified Polysemy.State              as PS
import           Polysemy.Writer             (Writer)

import           Effect.ByteStringStore      (ByteStringStore)
import           Effect.File                 (File)
import           Effect.Ginger               (GingerSemEffects)

import           Text.Ginger                 ((~>))
import qualified Text.Ginger                 as TG
import qualified Text.Ginger.Run.FuncUtils   as TF

import           Lib.Context.Core            (contextFromList, tryExtractIntArg)
import           Lib.Context.DynamicContexts (contentDynamic, summaryDynamic,
                                              tocDynamic)
import           Lib.Errors                  (SiteGenError)
import qualified Lib.Header                  as H
import           Lib.RouteUtils              (sameLevelRoutesAs)
import           Lib.SiteGenConfig           (SiteGenConfig)
import           Lib.SiteGenState            (SiteGenReader (..),
                                              SiteGenState (..))
import           Types.Context               (Context, ContextObject (..),
                                              ContextObjectTypes (..), RunSem,
                                              RunSemGVal,
                                              gValContextObjectTypeDictItemFor)
import           Types.SiteGenState          (Route)

import           Types.Pager                 (Pager (..), makePagerList,
                                              pagerListToTuples)

-- Provide contexts for the SourcePageContext and the VirtualPageContext records
-- They will be provided under the key 'header'


pageHeaderContextFor
    :: GingerSemEffects r
    => H.SourceContext
    -> Context (RunSem r)
pageHeaderContextFor sc = do
    let route = H.scRoute sc
    contextFromList
        $  [("Page", pageSourceContextM sc)
           ,("paginate", pure $ TG.fromFunction $ paginateF sc)
           ,("selectPages", pure $ TG.fromFunction $ selectPagesF sc)
           ]
        ++ [("Pages", pagesContextM route [route]) | H.scIndexPage sc]


pageSourceContextM
    :: GingerSemEffects r
    => H.SourceContext
    -> RunSemGVal r
pageSourceContextM (H.SPC spc) = sourcePageContextM spc
pageSourceContextM (H.VPC vpc) = virtualPageContextM vpc


sourcePageContextM
    :: GingerSemEffects r
    => H.SourcePageContext
    -> RunSemGVal r
sourcePageContextM spc = do
    -- TG.liftRun $ CP.log @String $ "Building sourcePageContextM for " ++ show (H.spcRoute spc)
    pure $ TG.toGVal spc


instance GingerSemEffects r => TG.ToGVal (RunSem r) H.SourcePageContext where
    toGVal spc =
        TG.dict
            [ gValContextObjectTypeDictItemFor SPCObjectType
            , "Route"           ~> H.spcRoute spc
            , "AbsFilePath"     ~> H.spcAbsFilePath spc
            , "RelFilePath"     ~> H.spcRelFilePath spc
            , "VimWikiLinkPath" ~> H.spcVimWikiLinkPath spc
            , "Title"           ~> H.spcTitle spc
            , "Template"        ~> H.spcTemplate spc
            , "Tags"            ~> H.spcTags spc
            , "Category"        ~> H.spcCategory spc
            , "Date"            ~> (tempToLocalTimeHelper <$> H.spcDate spc)
            , "Updated"         ~> (tempToLocalTimeHelper <$> H.spcUpdated spc)
            , "IndexPage"       ~> H.spcIndexPage spc
            , "Authors"         ~> H.spcAuthors spc
            , "Publish"         ~> H.spcPublish spc
            , "Draft"           ~> not (H.spcPublish spc)
            , "SiteId"          ~> H.spcSiteId spc
            -- note these are lower case initial as they are functions and need to
            -- be called from the template
            , ("content",          TG.fromFunction (contentDynamic (H.SPC spc)))
            , ("summary",          TG.fromFunction (summaryDynamic (H.SPC spc)))
            , ("toc",              TG.fromFunction (tocDynamic (H.SPC spc)))
            ]


-- | Construct a list of Pages for all of the direct sub-pages in this
-- collection.  The sub-pages are the pages in the same route that share the
-- same index.  We may also include the any index pages.  Sort by index pages
-- and then by alpha.  So if we have / and /thing and /thing/after then /thing
-- will be in Pages, but /thing/after won't be.  Obviously, every route has to
-- start with /, but then they all should.
-- TODO: finish this after we've worked out pagination.
pagesContextM
    :: GingerSemEffects r
    => Route         -- ^ the route with which to find associated pages
    -> [Route]       -- ^ a set of routes to exclude from the set of pages
    -> RunSemGVal r
pagesContextM route excludes = do
    scs <- TG.liftRun $ PR.asks @SiteGenReader siteSourceContexts
    let pages = sameLevelRoutesAs H.scRoute route scs
        pages' = filter (\p -> H.scRoute p `notElem` excludes) pages
    pagesM <- mapM pageSourceContextM pages'
    pure $ TG.list pagesM


virtualPageContextM :: Monad m => H.VirtualPageContext -> m (TG.GVal m)
virtualPageContextM vpc = pure $ TG.toGVal vpc


instance TG.ToGVal m H.VirtualPageContext where
    toGVal vpc =
        TG.dict
            [ gValContextObjectTypeDictItemFor SPCObjectType
            , "Route"           ~> H.vpcRoute vpc
            , "VimWikiLinkPath" ~> H.vpcVimWikiLinkPath vpc
            , "Title"           ~> H.vpcTitle vpc
            , "Template"        ~> H.vpcTemplate vpc
            , "Date"            ~> (tempToLocalTimeHelper <$> H.vpcDate vpc)
            , "Updated"         ~> (tempToLocalTimeHelper <$> H.vpcUpdated vpc)
            , "IndexPage"       ~> H.vpcIndexPage vpc
            , "Publish"         ~> H.vpcPublish vpc
            , "Draft"           ~> not (H.vpcPublish vpc)
            ]


-- convert a H.SourceContext into a GVal m
instance GingerSemEffects r => TG.ToGVal (RunSem r) H.SourceContext where
    toGVal (H.SPC v) = TG.toGVal v
    toGVal (H.VPC v) = TG.toGVal v


-- TODO: helper until I work out what to do with UTC time in the app, and how to
-- present it in pages.
tempToLocalTimeHelper :: UTCTime -> LocalTime
tempToLocalTimeHelper = utcToLocalTime utc



-- paginate functions -- helpers to do paginating of pages
--
-- | Paginate a set of pages.
-- The argument is a list of routes, in the order that the pager should work.
-- Note that subsequent calls to paginate that are from the 'same' pager (i.e.
-- the initial one) just return the next set of pages and do not recalculate the
-- set.  However, as the pages are immutable by that point, it should not make a
-- difference.  The optional size can control the number of elements in the
-- page.  This is FIXED after the first call; i.e. subsequent templates can
-- change it.
-- function in template:
-- paginate(List[str], size=Int) -> List[Page]
paginateF
    :: GingerSemEffects r
    => H.SourceContext     -- ^ the SourceContext is needed for the route
    -> TG.Function (RunSem r)
paginateF sc args = do
    -- get the sitePagerSet
    pagerSet <- TG.liftRun $ PS.gets @SiteGenState sitePagerSet
    let route = H.scRoute sc
    -- 1. parse the args to get the list of routes
    let (items, mSize) = extractListAndOptionalSize args
    if null items
        then do
            TG.liftRun $ CP.log @String "No Items provided to paginate() ?"
            pure def
            -- determine if there is a pager already for the current route
        else case HashMap.lookup route pagerSet of
            -- if so, just return the GVal m for that Pager
            Just pager -> pagerToGValM pager items
            Nothing -> do
                -- otherwise:
                let size = fromMaybe 10 mSize
                    pagerList = makePagerList route (length items) size
                -- 3. add the pagerset to the sitePagerSet
                let pagerSet' = HashMap.union pagerSet $ HashMap.fromList $ pagerListToTuples pagerList
                TG.liftRun $ PS.modify' @SiteGenState $ \sgs -> sgs {sitePagerSet=pagerSet'}
                let pager = pagerSet' HashMap.! route
                -- 4. return the GVal m for the first Pager
                pagerToGValM pager items


-- | convert a GVal m -> a ContextObjectType
fromGValToContextObjectType :: TG.GVal m -> Maybe ContextObjectTypes
fromGValToContextObjectType g = TG.lookupKey "_objectType_" g >>= \g' -> case TG.asText g' of
    ""        -> Nothing
    ":spc:"   -> Just SPCObjectType
    ":vpc:"   -> Just VPCObjectType
    ":tag:"   -> Just TagObjectType
    ":cat:"   -> Just CategoryObjectType
    ":pager:" -> Just PagerObjectType

--
-- convert the GVal m into a ContextObject
-- TODO this needs to become something that can be delegated back to the various
-- files that own these types.
fromGValToContextObject :: TG.GVal m -> Maybe ContextObject
fromGValToContextObject g = fromGValToContextObjectType g >>= \case
    SPCObjectType -> TG.lookupKey "Route" g >>= extractText >>= Just . SPCObject . T.unpack
    VPCObjectType -> TG.lookupKey "Route" g >>= extractText >>= Just . VPCObject . T.unpack
    _             -> Nothing


-- | extract out the text from a GVal m -> Just text if it's not an empty string
extractText :: TG.GVal m -> Maybe Text
extractText t = case TG.asText t of
    "" -> Nothing
    t' -> Just t'



pagerToGValM
    :: GingerSemEffects r
    => Pager                     -- ^ the SourceContext is needed for the route
    -> [TG.GVal (RunSem r)]         -- ^ the list of items that will paged back
    -> RunSemGVal r
pagerToGValM pager items = do
    let num = pagerItemsThisPage pager
        page = pagerThisPage pager
        maxSize = pagerMaxSize pager
        base = (page-1)*maxSize
    pure $ TG.dict
            [ gValContextObjectTypeDictItemFor PagerObjectType
            , "Route" ~> pagerRoute pager
            , "Routes" ~> pagerRoutes pager
            , "MaxSize" ~> maxSize
            , "ItemsThisPage" ~> num
            , "TotalItems" ~> pagerTotalItems pager
            , "NumPagers" ~> pagerNumPagers pager
            , "ThisPager"  ~> page
            , "ItemIndexes" ~> pagerItemIndexes pager
            , "AllItems" ~> TG.list items
            , "Items" ~> TG.list (take num $ drop base items)
            ]


extractListAndOptionalSize
    :: [(Maybe Text, TG.GVal m)]        -- ^ the args provided by Ginger
    -> ([TG.GVal m], Maybe Int)         -- ^ A list of Items and optional size (int)
extractListAndOptionalSize args =
    let (itemsHash, _, keyArgs, _) = TF.extractArgs ["items"] args
     in case HashMap.lookup "items" itemsHash of
        Nothing -> ([], Nothing)
        Just a -> case TG.asList a of
            Nothing -> ([], Nothing)
            Just ls -> (ls, TG.toInt =<< HashMap.lookup "size" keyArgs)

---

-- | Select pages using a route.  If the route is missing, use the SourceContext
-- provided.
-- selectPages(Str, include_self=Optional[Bool]) -> List[Pages]
selectPagesF
    :: GingerSemEffects r
    => H.SourceContext     -- ^ the SourceContext is needed for the route
    -> TG.Function (RunSem r)
selectPagesF sc args = do
    pagerSet <- TG.liftRun $ PS.gets @SiteGenState sitePagerSet
    let routeSc = H.scRoute sc
        (argRoute, argIncSelf) = extractRouteAndOptionalIncludeArgs args
        route = fromMaybe routeSc argRoute
        mPagerSet = HashMap.lookup routeSc pagerSet
    let excludesp = maybe [] pagerRoutes mPagerSet
        excludes = if argIncSelf
                     then filter (/=routeSc) excludesp
                     else routeSc : excludesp
    pagesContextM route excludes


-- | extract a route and include_self=Bool
extractRouteAndOptionalIncludeArgs
    :: [(Maybe Text, TG.GVal m)]     -- ^ the args provided by Ginger
    -> (Maybe Route, Bool)           -- ^ A list of Items and optional size (int)
extractRouteAndOptionalIncludeArgs args =
    let (itemsHash, _, keyArgs, _) = TF.extractArgs ["route"] args
        route = T.unpack . TG.asText <$> HashMap.lookup "route" itemsHash
        includeSelf = maybe False TG.toBoolean (HashMap.lookup "include_self" keyArgs)
     in case route of
         Nothing -> (Nothing, includeSelf)
         Just "" -> (Nothing, includeSelf)
         Just s  -> (Just s, includeSelf)
