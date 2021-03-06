{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
module CR.Client where

import Network.Wreq

import Web.Spock (renderRoute)
import Control.Monad
import qualified Data.Traversable as T
import Control.Lens
import Crypto.Hash
import Data.Aeson (toJSON, encode, eitherDecode')
import Data.Byteable
import GHC.Generics
import Data.Time.Clock
import CR.InterfaceTypes
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Bytes.Serial as SE
import Data.Bytes.Put
import System.Directory
import System.Process
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data BuildStep
   = BuildStep
   { bs_cmdLine :: !String
   -- ^ System command to perform build step
   , bs_dependencies :: !(S.Set FilePath)
   -- ^ Files this build step depends on
   , bs_expectedOutputFiles :: !(M.Map BuildFileType FilePath)
   -- ^ Files this build step will produce
   , bs_additionalArgs :: !(M.Map T.Text T.Text)
   -- ^ Key-Value-pairs the result of this build step depends on, e.g. architecture
   -- compiler version
   , bs_name :: !String
   -- ^ Name for the Buildstep
   , bs_version :: !Int
   -- ^ Version of the Buildstep
   , bs_cpuArch :: !CpuArch
   }
   deriving (Show, Eq, Generic)

instance SE.Serial BuildStep where

data ClientArgs
    = ClientArgs
    { c_bs :: BuildStep
    -- ^ Build-step we want to try to cache
    , c_bloomFilter :: FilePath
    -- ^ Bloom-Filter with an upper-approximation of all cached build steps
    , c_url :: String
    -- ^ URL to the Compile Registry
    }

computeHash :: BuildStep -> IO InputHash
computeHash buildstep =
    do depHashes <- forM (S.toAscList $ bs_dependencies buildstep) (liftM md5Hash . BS.readFile)
       return
           $ InputHash
           $ TE.decodeUtf8
           $ digestToHexByteString
           $ md5Hash
           $ BS.concat
           $ map toBytes
           $ (md5Hash buildstepBS):depHashes
    where
      buildstepBS = runPutS $ SE.serialize buildstep
      md5Hash :: BS.ByteString -> Digest MD5
      md5Hash = hash

trackCmdTime :: IO () -> IO Double
trackCmdTime cmd =
    do start <- getCurrentTime
       cmd
       end <- getCurrentTime
       return $ realToFrac $ diffUTCTime end start

loadBloomFilter :: CpuArch -> FilePath -> IO (Either String BloomFilter)
loadBloomFilter arch bloomFilterFile =
    do isThere <- doesFileExist bloomFilterFile
       if isThere
       then do bsl <- BSL.readFile bloomFilterFile
               case eitherDecode' bsl of
                 Left errMsg ->
                     return (Left errMsg)
                 Right ok ->
                     if bre_cpuArch ok /= arch
                     then return $ Left $
                              "Bloom filter file " ++ bloomFilterFile
                              ++ " is for wrong cpu arch (is: " ++ T.unpack (unCpuArch (bre_cpuArch ok))
                              ++ ", needed: " ++ T.unpack (unCpuArch arch) ++ ")"
                     else case parseBloomFilter ok of
                            Nothing ->
                                return $ Left "Invalid bloom filter bits"
                            Just bf -> return $ Right bf
       else return (Left $ "Bloom filter file " ++ bloomFilterFile ++ " not present!")

updateBloomFilter :: CpuArch -> String -> FilePath -> IO ()
updateBloomFilter arch url bloomFilterFile =
    do response <-
           post (url ++ T.unpack (renderRoute loadBloomEndpoint)) $ toJSON $
           BloomRequest
           { br_cpuArch = arch
           }
       responseJ <- asJSON response
       case responseJ ^. responseBody of
         BloomResponseFailed ->
             fail "Failed to download bloomfilter!"
         BloomResponseOk bloomData ->
             BSL.writeFile bloomFilterFile (encode bloomData)

client :: ClientArgs -> IO ()
client args =
    do inputHash <- computeHash (c_bs args)
       let runNotCached =
               buildStepNotCached inputHash (c_url args) (c_bs args)
       mBloom <- loadBloomFilter (bs_cpuArch $ c_bs args) (c_bloomFilter args)
       case mBloom of
         Right bloom | bloomContains inputHash bloom ->
             do response <- post (c_url args ++ T.unpack (renderRoute loadEntryEndpoint)) $ toJSON $
                   Request
                   { r_inputHash = inputHash
                   ,  r_cpuArch = bs_cpuArch $ c_bs args
                   }
                responseJ <- asJSON response
                let expectedOutputFiles = bs_expectedOutputFiles $ c_bs args
                case responseJ ^. responseBody of
                  ResponseCached files
                      | (M.keysSet files) == (M.keysSet expectedOutputFiles) ->
                          forM_ (M.keysSet files) $ \ft ->
                              BS.writeFile (expectedOutputFiles M.! ft) (unBase64 $ files M.! ft)
                      | otherwise -> fail "Set of cached files distinct from expected list."
                  ResponseNotFound -> runNotCached
         Right _ -> runNotCached
         Left err ->
             do putStrLn ("Warning: not using bloom filter: " ++ err)
                runNotCached

buildStepNotCached :: InputHash -> String -> BuildStep -> IO ()
buildStepNotCached inputHash url bs =
    do time <- trackCmdTime $ callCommand (bs_cmdLine bs)
       -- TODO: Would be cool - to do this in a seperate thread
       forM_ (bs_expectedOutputFiles bs) $ \fp ->
           do doesExist <- doesFileExist fp
              unless doesExist $ fail $ concat ["Expected output file: ", fp, " was missing!"]
       files <- flip T.mapM (bs_expectedOutputFiles bs) $ liftM AsBase64 . BS.readFile
       _ <- put (url ++ T.unpack (renderRoute storeEntryEndpoint)) $ toJSON $
           UploadFiles
           { uf_inputHash = inputHash
           , uf_buildTimeSeconds = time
           , uf_files = files
           , uf_cpuArch = bs_cpuArch bs
           }
       return ()
