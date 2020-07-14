module Types.Header where


import           Data.Default.Class (Default, def)
import           Data.Time.Clock    (UTCTime)
import qualified Data.Yaml          as Y


data SourceMetadata = SourceMetadata
    { smRoute           :: !String
    , smAbsFilePath     :: !(Maybe FilePath)
    , smRelFilePath     :: !(Maybe FilePath)
    , smVimWikiLinkPath :: !String
    , smTitle           :: !String
    , smTemplate        :: !String
    , smTags            :: ![String]
    , smCategory        :: !(Maybe String)
    , smDate            :: !(Maybe UTCTime)
    , smUpdated         :: !(Maybe UTCTime)
    , smIndexPage       :: !Bool
    , smAuthors         :: ![String]
    , smPublish         :: !Bool
    , smSiteId          :: !String
    , smHeaderLen       :: !Int   -- the length of the headerblock; i.e. what to drop to get to the content.
    , smParams          :: !(Maybe Y.Object)
    } deriving (Show, Eq)



instance Default SourceMetadata where
    def = SourceMetadata
        { smRoute=def
        , smAbsFilePath=def
        , smRelFilePath=def
        , smVimWikiLinkPath=def
        , smTitle=def
        , smTemplate=def
        , smTags=def
        , smCategory=def
        , smDate=def
        , smUpdated=def
        , smIndexPage=False
        , smAuthors=def
        , smPublish=False
        , smSiteId=def
        , smHeaderLen=def
        , smParams=def
        }

