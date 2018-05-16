{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.ByteString.Streaming.Char8 as Q
import qualified Streaming.Prelude               as S
import           Data.JsonStream.Parser          (Parser, parseByteString, value)
import           Data.Aeson                      (FromJSON)
import           Data.Function                   ((&))
import qualified Kubernetes.API.AppsV1
import           Kubernetes.Model                (V1Deployment)
import qualified Kubernetes.ModelLens            as L
import           Kubernetes.Client               (dispatchMime)
import           Kubernetes.ClientHelper         (setMasterURI, disableValidateAuthMethods,
                                                  defaultTLSClientParams, disableServerNameValidation,
                                                  setCAStore, setClientCert, loadPEMCerts, newManager)
import           Kubernetes.Core                 (newConfig, KubernetesConfig)
import           Kubernetes.KubeConfig           (AuthInfo (..), Cluster (..), Config,
                                                  getAuthInfo, getCluster)
import           Kubernetes.MimeTypes            (Accept (..), MimeJSON (..))
import           Kubernetes.Watch.Client         (dispatchWatch, WatchEvent, eventType, eventObject)
import           Network.TLS                     (credentialLoadX509, Credential)
import qualified Network.HTTP.Client             as NH
import           Data.Yaml                       (decodeFileEither, prettyPrintParseException)
import           Data.Text                       (unpack)
import           Data.Traversable                (traverse)
import           Control.Arrow                   (left)
import           Lens.Micro.Platform             ((^.), (^..), to, _Just, each)

type Change = (String, String, [String])

maybeToEither :: String -> Maybe a -> Either String a
maybeToEither = flip maybe Right . Left
combine :: Either a b -> Either a c -> Either a (b, c)
combine a b = do
    a' <- a
    b' <- b
    return (a', b')

buildConf :: Either String Config -> IO (Either String KubernetesConfig)
buildConf configFile =
    (configFile >>= getCluster)
    & fmap server
    & traverse (\masterURI ->
        newConfig
        & fmap (setMasterURI masterURI)
        & fmap disableValidateAuthMethods
    )

getCertConf :: Either String Config -> Either String (FilePath, FilePath)
getCertConf configFile = do
    conf <- configFile
    authInfo <- snd <$> getAuthInfo conf
    clientCertFile <- maybeToEither "Client certificate missing" $ clientCertificate authInfo
    clientKeyFile <- maybeToEither "Client key missing" $ clientKey authInfo
    return (clientCertFile, clientKeyFile)

loadCert :: Either String Config -> IO (Either String Credential)
loadCert = either (return . Left) (uncurry credentialLoadX509) . getCertConf

buildManager :: Either String Config -> IO (Either String NH.Manager)
buildManager configFile = do
    let cluster = configFile >>= getCluster
    let caPath = fmap certificateAuthority cluster >>= maybeToEither "CA missing"
    myCAStore <- traverse loadPEMCerts $ unpack <$> caPath
    myCert <- loadCert configFile
    tlsParams <-
        traverse (\(ca, cert) ->
            defaultTLSClientParams
            & fmap disableServerNameValidation
            & fmap (setCAStore ca)
            & fmap (setClientCert cert)
        ) (combine myCAStore myCert)
    traverse newManager tlsParams

getConf :: FilePath -> IO (Either String (NH.Manager, KubernetesConfig))
getConf path = do
    configFile <- left prettyPrintParseException <$> decodeFileEither path
    kcfg <- buildConf configFile
    manager <- buildManager configFile
    return $ combine manager kcfg

-- | Parse the stream using the given parser.
streamParse ::
  FromJSON a =>
    Parser a
    -> Q.ByteString IO r
    -> S.Stream (S.Of [a]) IO r
streamParse parser byteStream = byteStream & Q.lines & parseEvent parser

-- | Parse a single event from the stream.
parseEvent ::
  (FromJSON a, Monad m) =>
    Parser a
    -> S.Stream (Q.ByteString m) m r
    -> S.Stream (S.Of [a]) m r
parseEvent parser byteStream = S.map (parseByteString parser) (S.mapped Q.toStrict byteStream)

commitMessageFor' :: Change -> String
commitMessageFor' ("ADDED", name, images) = "Add deployment " ++ name
commitMessageFor' ("MODIFIED", name, images) = "Update deployment " ++ name
commitMessageFor' (t, _, _) = error $ "Unexpected type: " ++ t
commitMessageFor :: WatchEvent V1Deployment -> String
commitMessageFor = commitMessageFor' . changeFromDeploymentEvent

changeFromDeploymentEvent :: WatchEvent V1Deployment -> Change
changeFromDeploymentEvent event = ((unpack . eventType) event, event^.deployNameL, event^..imagesL)
    where deployNameL = to eventObject . L.v1DeploymentMetadataL . _Just . L.v1ObjectMetaNameL . _Just . to unpack
          imagesL = podSpecL .  L.v1PodSpecContainersL . each .  L.v1ContainerImageL . _Just . to unpack
          podSpecL = deploySpecL . L.v1DeploymentSpecTemplateL .  L.v1PodTemplateSpecSpecL . _Just
          deploySpecL = to eventObject .  L.v1DeploymentSpecL . _Just

eventParser :: Parser (WatchEvent V1Deployment)
eventParser = value

main :: IO ()
main = do
    putStrLn "Starting"
    conf <- either error id <$> getConf "/Users/deiwin/.kube/config"
    let request = Kubernetes.API.AppsV1.listDeploymentForAllNamespaces (Accept MimeJSON)
    let withResponseBody body = streamParse eventParser body & S.map (map commitMessageFor)
    uncurry dispatchWatch conf request (S.print . withResponseBody)
