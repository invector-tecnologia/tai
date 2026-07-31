## OAuth 2.0 device-code login (configurable endpoints).

import std/[httpclient, json, strutils, os, osproc, uri]

type
  DeviceFlowStart* = object
    ok*: bool
    message*: string
    deviceCode*: string
    userCode*: string
    verifyUrl*: string
    interval*: int
    expiresIn*: int

  DeviceFlowToken* = object
    ok*: bool
    message*: string
    accessToken*: string
    refreshToken*: string

proc formEnc(s: string): string =
  encodeUrl(s, usePlus = false)

proc startDeviceFlow*(
    deviceAuthUrl, clientId: string, scope = "openid"
): DeviceFlowStart =
  if deviceAuthUrl.len == 0 or clientId.len == 0:
    return DeviceFlowStart(
      ok: false,
      message: "OAuth not configured — set ai.oauth_client_id / device_auth_url / token_url or :login <token>",
    )
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
  let body = "client_id=" & formEnc(clientId) & "&scope=" & formEnc(scope)
  try:
    let resp = client.postContent(deviceAuthUrl, body)
    let j = parseJson(resp)
    result.ok = true
    result.deviceCode = j{"device_code"}.getStr
    result.userCode = j{"user_code"}.getStr
    result.verifyUrl = j{"verification_uri"}.getStr
    if result.verifyUrl.len == 0:
      result.verifyUrl = j{"verification_uri_complete"}.getStr
    result.interval = j{"interval"}.getInt
    if result.interval <= 0: result.interval = 5
    result.expiresIn = j{"expires_in"}.getInt
    result.message = "Visit " & result.verifyUrl & " and enter code " & result.userCode
  except CatchableError as e:
    result = DeviceFlowStart(ok: false, message: e.msg)

proc pollDeviceToken*(
    tokenUrl, clientId, deviceCode: string
): DeviceFlowToken =
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
  let body =
    "grant_type=" & formEnc("urn:ietf:params:oauth:grant-type:device_code") &
    "&device_code=" & formEnc(deviceCode) &
    "&client_id=" & formEnc(clientId)
  try:
    let resp = client.postContent(tokenUrl, body)
    let j = parseJson(resp)
    if j.hasKey("access_token"):
      result.ok = true
      result.accessToken = j["access_token"].getStr
      result.refreshToken = j{"refresh_token"}.getStr
      result.message = "token acquired"
    elif j{"error"}.getStr in ["authorization_pending", "slow_down"]:
      result.ok = false
      result.message = j["error"].getStr
    else:
      result.ok = false
      result.message = j{"error_description"}.getStr
      if result.message.len == 0: result.message = $j
  except CatchableError as e:
    result = DeviceFlowToken(ok: false, message: e.msg)

proc saveCredentials*(access, refresh: string) =
  let path = getConfigDir() / "tai" / "credentials"
  createDir(parentDir(path))
  writeFile(path, $(%*{"access_token": access, "refresh_token": refresh}))
  discard execCmdEx("chmod 600 " & quoteShell(path))

proc loadCredentials*: tuple[access, refresh: string] =
  let path = getConfigDir() / "tai" / "credentials"
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    result.access = j{"access_token"}.getStr
    result.refresh = j{"refresh_token"}.getStr
  except CatchableError:
    discard
