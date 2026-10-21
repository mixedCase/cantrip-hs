#!/usr/bin/env cantrip
-- Exchange a stored OAuth refresh token for a new access token, and save it.
import Cantrip

main :: IO ()
main = jsonScript $ \argv -> do
    args <- parseArgs ["dry-run", "TOKEN_FILE"] argv
    let file = positional "TOKEN_FILE" args

    saved <- readJsonFile file
    refresh <- expect "no refresh token in the file" (str "refresh" saved)

    req <- request "POST https://auth.example.com/oauth/token"
    let form = [("grant_type", "refresh_token"), ("refresh_token", encodeUtf8 refresh)]
    resp <- http (setRequestBodyURLEncoded form req)
    when (getResponseStatusCode resp == 401) (failWith "refresh token rejected; log in again")

    token <- expectJson resp
    access <- expect "no access_token in the response" (str "access_token" token)

    unless (switch "dry-run" args) $
        modifyJsonFile file 0o600 (\current -> return (upsert "access" (String access) current))

    return (object ["expiresIn" .= int "expires_in" token])
