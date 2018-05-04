{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Function             ((&))
import qualified Kubernetes.API.CoreV1
import           Kubernetes.Client         (dispatchMime)
import           Kubernetes.ClientHelper   (setMasterURI, disableValidateAuthMethods,
                                            defaultTLSClientParams, disableServerNameValidation,
                                            setCAStore, setClientCert, loadPEMCerts, newManager)
import           Kubernetes.Core           (newConfig, KubernetesConfig)
import           Kubernetes.KubeConfig     (AuthInfo (..), Cluster (..), Config,
                                            getAuthInfo, getCluster)
import           Kubernetes.MimeTypes      (Accept (..), MimeJSON (..))
import           Network.TLS               (credentialLoadX509, Credential)
import qualified Network.HTTP.Client       as NH
import           Data.Yaml                 (decodeFileEither, prettyPrintParseException)
import           Data.Text                 (unpack)
import           Control.Arrow             (left)
import           Control.Monad             (mapM)

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

main :: IO ()
main = do
    putStrLn "Starting"
    conf <- either error id <$> getConf "/Users/deiwin/.kube/config"
    uncurry dispatchMime
        conf
        (Kubernetes.API.CoreV1.listPodForAllNamespaces (Accept MimeJSON)) >>=
        print
