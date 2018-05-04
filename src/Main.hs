{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Data.ByteString.Streaming.Char8 as Q
import qualified Streaming.Prelude               as S
import           Data.JsonStream.Parser          (Parser, parseByteString, value)
import           Data.Aeson                      (FromJSON)
import           Data.Function                   ((&))
import qualified Kubernetes.API.AppsV1
import           Kubernetes.Model                (V1Deployment)
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
import           Control.Arrow                   (left)
import           Control.Monad                   (mapM)

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
    & mapM (\masterURI ->
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
    myCAStore <- mapM loadPEMCerts $ unpack <$> caPath
    myCert <- loadCert configFile
    tlsParams <-
        mapM (\(ca, cert) ->
            defaultTLSClientParams
            & fmap disableServerNameValidation
            & fmap (setCAStore ca)
            & fmap (setClientCert cert)
        ) (combine myCAStore myCert)
    mapM newManager tlsParams

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

main :: IO ()
main = do
    putStrLn "Starting"
    conf <- either error id <$> getConf "/Users/deiwin/.kube/config"
    let request = Kubernetes.API.AppsV1.listDeploymentForAllNamespaces (Accept MimeJSON)
    let eventParser :: Parser (WatchEvent V1Deployment) = value
    let withResponseBody body = streamParse eventParser body & S.map (map (\x -> (eventType x, eventObject x)))
    uncurry dispatchWatch conf request (S.print . withResponseBody)
