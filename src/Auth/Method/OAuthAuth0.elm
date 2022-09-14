module Auth.Method.OAuthAuth0 exposing (..)

import Auth.Common exposing (..)
import Auth.Protocol.OAuth
import Base64.Encode as Base64
import Bytes exposing (Bytes)
import Bytes.Encode as Bytes
import Config
import Dict exposing (Dict)
import Env exposing (..)
import Http
import HttpHelpers
import JWT exposing (..)
import JWT.JWS as JWS
import Json.Decode as Json
import OAuth
import OAuth.AuthorizationCode as OAuth
import Task exposing (Task)
import Url exposing (Protocol(..), Url)
import Url.Builder exposing (absolute)


configuration :
    String
    -> String
    ->
        Configuration
            frontendMsg
            backendMsg
            { frontendModel | authFlow : Flow, authRedirectBaseUrl : Url }
            backendModel
configuration clientId clientSecret =
    ProtocolOAuth
        { id = "OAuthAuth0"
        , authorizationEndpoint = { defaultHttpsUrl | host = Config.auth0AppTenant, path = "/authorize" }
        , tokenEndpoint = { defaultHttpsUrl | host = Config.auth0AppTenant, path = "/oauth/token" }
        , onLogout = getLogout
        , clientId = clientId
        , clientSecret = clientSecret
        , scope = [ "openid email profile" ]
        , getUserInfo = getUserInfo
        , onFrontendCallbackInit = Auth.Protocol.OAuth.onFrontendCallbackInit
        , placeholder = \x -> ()

        -- , onAuthCallbackReceived = Debug.todo "onAuthCallbackReceived"
        }


getUserInfo :
    OAuth.AuthenticationSuccess
    -> Task Auth.Common.Error UserInfo
getUserInfo authenticationSuccess =
    let
        extract : String -> Json.Decoder a -> Dict String Json.Value -> Result String a
        extract k d v =
            Dict.get k v
                |> Maybe.map
                    (\v_ ->
                        Json.decodeValue d v_
                            |> Result.mapError Json.errorToString
                    )
                |> Maybe.withDefault (Err <| "Key " ++ k ++ " not found")

        extractOptional : a -> String -> Json.Decoder a -> Dict String Json.Value -> Result String a
        extractOptional default k d v =
            Dict.get k v
                |> Maybe.map
                    (\v_ ->
                        Json.decodeValue d v_
                            |> Result.mapError Json.errorToString
                    )
                |> Maybe.withDefault (Ok <| default)

        tokenR =
            case authenticationSuccess.idJwt of
                Nothing ->
                    Err "Identity JWT missing in authentication response. Please report this issue."

                Just idJwt ->
                    case JWT.fromString idJwt of
                        Ok (JWS t) ->
                            Ok t

                        Err err ->
                            Err <| jwtErrorToString err

        stuff =
            tokenR
                |> Result.andThen
                    (\token ->
                        let
                            meta =
                                token.claims.metadata
                        in
                        Result.map4
                            (\email email_verified given_name family_name ->
                                { email = email
                                , email_verified = email_verified
                                , given_name = given_name
                                , family_name = family_name
                                }
                            )
                            (extract "email" Json.string meta)
                            (extractOptional Nothing "email_verified" (Json.bool |> Json.nullable) meta)
                            (extractOptional Nothing "given_name" (Json.string |> Json.nullable) meta)
                            (extractOptional Nothing "family_name" (Json.string |> Json.nullable) meta)
                    )
    in
    Task.mapError (Auth.Common.ErrAuthString << HttpHelpers.httpErrorToString) <|
        case stuff of
            Ok result ->
                Task.succeed
                    { name = Maybe.withDefault "" result.given_name ++ " " ++ Maybe.withDefault "" result.family_name
                    , email = result.email
                    , username = Nothing
                    }

            Err err ->
                Task.fail (Http.BadBody err)


getLogout : Auth.Common.Token -> (BackendMsg -> backendMsg) -> Cmd backendMsg
getLogout authToken asBackendMsg =
    let
        url =
            { defaultHttpsUrl | host = Config.auth0AppTenant, path = "/v2/logout" }
    in
    Http.request
        { method = "GET"
        , headers = OAuth.useToken authToken.token []
        , url = "https://windschools.eu.auth0.com/v2/logout?client_id=9hTzuV6SkonCobIyE9K13YINAq1XLgT9&returnTo=http://localhost:8000/"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Auth.Common.AuthLogoutResponse
        , timeout = Nothing
        , tracker = Nothing
        }
        |> Cmd.map asBackendMsg


jwtErrorToString err =
    case err of
        TokenTypeUnknown ->
            "Unsupported auth token type."

        JWSError decodeError ->
            case decodeError of
                JWS.Base64DecodeError ->
                    "Base64DecodeError"

                JWS.MalformedSignature ->
                    "MalformedSignature"

                JWS.InvalidHeader jsonError ->
                    "InvalidHeader: " ++ Json.errorToString jsonError

                JWS.InvalidClaims jsonError ->
                    "InvalidClaims: " ++ Json.errorToString jsonError
