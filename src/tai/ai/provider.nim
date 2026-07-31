## AI provider auth (API key + web/device-code style login) and chat completion.

import std/[httpclient, json, strutils, os, options]
import ../config
import ./cache
import ./rag
import ./rtk

type
  ChatMessage* = object
    role*: string
    content*: string

  AiSession* = object
    cfg*: AiConfig
    messages*: seq[string] ## display lines in bottom panel
    input*: string
    busy*: bool
    promptCache*: PromptCache
    contextCache*: ContextCache
    semanticCache*: SemanticCache
    rag*: RagIndex
    stats*: TokenStats
    systemPrompt*: string

proc initAiSession*(cfg: AiConfig, cacheDir: string): AiSession =
  result.cfg = cfg
  result.messages = @["Tai AI ready. :login | :provider | type a message below."]
  result.promptCache = initPromptCache()
  result.contextCache = initContextCache()
  result.semanticCache = initSemanticCache(cacheDir / "semantic.json")
  result.systemPrompt = """
You are Tai's embedded coding assistant inside a TUI editor.
Be concise. Prefer actionable edits. Respect the user's open buffer context.
""".strip()
  result.promptCache.put("system", result.systemPrompt)

proc hasCredentials*(s: AiSession): bool =
  s.cfg.apiKey.len > 0 or s.cfg.authToken.len > 0

proc authHeader(s: AiSession): string =
  if s.cfg.authToken.len > 0: s.cfg.authToken
  else: s.cfg.apiKey

proc startWebLogin*(s: var AiSession): string =
  ## Device-code / loopback style login helper.
  ## Opens a local callback URL instruction; stores a placeholder until user pastes token.
  let port = 8765
  let url = "http://127.0.0.1:" & $port & "/callback"
  s.messages.add "Auth web: visit your provider's OAuth page and paste the token with :login <token>"
  s.messages.add "Loopback expected at " & url
  "web auth initiated"

proc setApiKey*(s: var AiSession, key: string) =
  s.cfg.apiKey = key
  s.messages.add "API key set (" & $key.len & " chars)"

proc setProvider*(s: var AiSession, name: string) =
  case name.toLowerAscii
  of "openai", "openai-compat":
    s.cfg.provider = apkOpenAiCompat
    if s.cfg.baseUrl.len == 0:
      s.cfg.baseUrl = "https://api.openai.com/v1"
  of "anthropic":
    s.cfg.provider = apkAnthropic
    s.cfg.baseUrl = "https://api.anthropic.com"
  of "google":
    s.cfg.provider = apkGoogle
    s.cfg.baseUrl = "https://generativelanguage.googleapis.com"
  of "ollama", "local":
    s.cfg.provider = apkOllama
    s.cfg.baseUrl = "http://127.0.0.1:11434/v1"
  else:
    s.messages.add "unknown provider: " & name
    return
  s.messages.add "provider: " & name

proc buildMessages(s: AiSession, userPrompt, ragCtx, bufferCtx: string): JsonNode =
  result = newJArray()
  result.add %*{"role": "system", "content": s.systemPrompt}
  let ctx = s.contextCache.contextBlock()
  if ctx.len > 0:
    result.add %*{"role": "system", "content": "Session context:\n" & ctx}
  if ragCtx.len > 0:
    result.add %*{"role": "system", "content": ragCtx}
  if bufferCtx.len > 0:
    result.add %*{"role": "system", "content": "Current buffer:\n" & bufferCtx}
  result.add %*{"role": "user", "content": userPrompt}

proc chatOpenAiCompat(s: var AiSession, messages: JsonNode): string =
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & s.authHeader,
  })
  let body = %*{
    "model": s.cfg.model,
    "messages": messages,
    "temperature": 0.2,
  }
  let url = s.cfg.baseUrl.strip(leading = false, trailing = true, chars = {'/'}) & "/chat/completions"
  let resp = client.postContent(url, $body)
  let j = parseJson(resp)
  if j.hasKey("usage"):
    s.stats.promptTokens += j["usage"]{"prompt_tokens"}.getInt
    s.stats.completionTokens += j["usage"]{"completion_tokens"}.getInt
  result = j["choices"][0]["message"]["content"].getStr

proc chatAnthropic(s: var AiSession, userPrompt, ragCtx, bufferCtx: string): string =
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "x-api-key": s.authHeader,
    "anthropic-version": "2023-06-01",
  })
  var system = s.systemPrompt
  if ragCtx.len > 0: system.add "\n" & ragCtx
  if bufferCtx.len > 0: system.add "\n" & bufferCtx
  let body = %*{
    "model": if s.cfg.model.len > 0: s.cfg.model else: "claude-3-5-haiku-latest",
    "max_tokens": 2048,
    "system": system,
    "messages": [%*{"role": "user", "content": userPrompt}],
  }
  let resp = client.postContent(s.cfg.baseUrl.strip(chars = {'/'}) & "/v1/messages", $body)
  let j = parseJson(resp)
  result = j["content"][0]["text"].getStr

proc ask*(
    s: var AiSession,
    userPrompt: string,
    bufferCtx = "",
    runShell = "",
): string =
  if not s.hasCredentials and s.cfg.provider != apkOllama:
    return "No credentials. Use :login <token> or set ai.api_key / TAI_API_KEY."

  # Semantic cache hit
  let cached = s.semanticCache.get(userPrompt & "\n" & bufferCtx)
  if cached.isSome:
    inc s.stats.savedTokens, estimateTokens(cached.get)
    s.messages.add "assistant (cache): " & cached.get
    s.contextCache.appendTurn("assistant", cached.get)
    return cached.get

  var ragCtx = ""
  if s.rag.chunks.len > 0:
    ragCtx = formatContext(retrieve(s.rag, userPrompt))

  var shellCtx = ""
  if runShell.len > 0:
    let r = runWithRtk(runShell)
    s.stats.rtkSavedTokens += r.savedTokens
    shellCtx = "Command output" & (if r.usedRtk: " (rtk)" else: "") & ":\n" & r.output
    if shellCtx.len > 0:
      ragCtx.add "\n" & shellCtx

  s.busy = true
  s.messages.add "user: " & userPrompt
  try:
    var answer: string
    case s.cfg.provider
    of apkAnthropic:
      answer = s.chatAnthropic(userPrompt, ragCtx, bufferCtx)
    else:
      let msgs = s.buildMessages(userPrompt, ragCtx, bufferCtx)
      answer = s.chatOpenAiCompat(msgs)
    s.semanticCache.put(userPrompt & "\n" & bufferCtx, answer)
    s.contextCache.appendTurn("user", userPrompt)
    s.contextCache.appendTurn("assistant", answer)
    s.messages.add "assistant: " & answer
    # keep message panel bounded
    if s.messages.len > 200:
      s.messages = s.messages[^120 .. ^1]
    result = answer
  except CatchableError as e:
    result = "AI error: " & e.msg
    s.messages.add result
  finally:
    s.busy = false
