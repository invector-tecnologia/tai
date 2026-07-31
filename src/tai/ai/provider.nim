## AI provider auth, chat completion, tool loop, project memory, sessions.

import std/[httpclient, json, strutils, os, atomics]
import std/typedthreads
import ../config
import ./cache
import ./rag
import ./rtk
import ./tools

type
  AiJobKind* = enum
    ajNone
    ajDone
    ajError
    ajChunk
    ajTool

  AiJobEvent* = object
    kind*: AiJobKind
    text*: string

  AiJobArgs* = object
    cfg*: AiConfig
    systemPrompt*: string
    prompt*: string
    bufferCtx*: string
    ragCtx*: string
    workspace*: string
    useTools*: bool
    allowDangerous*: bool
    cancel*: ptr Atomic[bool]
    transcriptCtx*: string

  AiSession* = object
    cfg*: AiConfig
    messages*: seq[string]
    input*: string
    busy*: bool
    cancelRequested*: Atomic[bool]
    promptCache*: PromptCache
    contextCache*: ContextCache
    responseCache*: ResponseCache
    rag*: RagIndex
    stats*: TokenStats
    systemPrompt*: string
    projectMemory*: string
    workspace*: string
    sessionPath*: string
    scroll*: int
    allowDangerous*: bool
    useTools*: bool

var aiEventChan: Channel[AiJobEvent]
var aiChanReady: bool
var gAiThread: Thread[AiJobArgs]
var gAiThreadLive: bool

proc ensureAiChan() =
  if not aiChanReady:
    aiEventChan.open(64)
    aiChanReady = true

proc pushMsg*(s: var AiSession, line: string) =
  s.messages.add line
  if s.messages.len > 400:
    s.messages = s.messages[^300 .. ^1]

proc loadProjectMemory*(root: string): string =
  var parts: seq[string]
  for name in ["AGENTS.md", "CLAUDE.md", "GEMINI.md"]:
    let p = root / name
    if fileExists(p):
      try:
        let body = readFile(p)
        if body.len > 0:
          parts.add "# " & name & "\n" & body
      except CatchableError:
        discard
  parts.join("\n\n")

proc baseSystemPrompt(): string =
  """
You are Tai's embedded coding assistant inside a TUI editor.
Be concise. Prefer actionable edits. Use tools when they help.
Respect open buffer context and project instruction files.
""".strip()

proc rebuildSystem*(s: var AiSession) =
  var parts = @[baseSystemPrompt()]
  if s.projectMemory.len > 0:
    parts.add "Project instructions:\n" & s.projectMemory
  s.systemPrompt = parts.join("\n\n")
  s.promptCache.put("system", s.systemPrompt)

proc saveSession*(s: AiSession) =
  if s.sessionPath.len == 0: return
  try:
    createDir(parentDir(s.sessionPath))
    writeFile(s.sessionPath, $( %*{"messages": s.messages} ))
  except CatchableError:
    discard

proc loadSession(s: var AiSession) =
  if s.sessionPath.len == 0 or not fileExists(s.sessionPath): return
  try:
    let j = parseJson(readFile(s.sessionPath))
    if j.hasKey("messages"):
      s.messages = @[]
      for m in j["messages"]:
        s.messages.add m.getStr
  except CatchableError:
    discard

proc initAiSession*(cfg: AiConfig, cacheDir, workspace: string): AiSession =
  ensureAiChan()
  result.cfg = cfg
  result.workspace = workspace
  result.promptCache = initPromptCache()
  result.contextCache = initContextCache()
  result.responseCache = initResponseCache(cacheDir / "responses.json")
  result.sessionPath = cacheDir / "session.json"
  result.useTools = true
  result.allowDangerous = false
  result.projectMemory = loadProjectMemory(workspace)
  result.rebuildSystem()
  result.loadSession()
  if result.messages.len == 0:
    result.messages = @[
      "Tai AI ready. :login | :provider | :model | :agent on|off | :rag reindex",
    ]
  result.cancelRequested.store(false)

proc hasCredentials*(s: AiSession): bool =
  s.cfg.apiKey.len > 0 or s.cfg.authToken.len > 0 or s.cfg.provider == apkOllama

proc authHeader(cfg: AiConfig): string =
  if cfg.authToken.len > 0: cfg.authToken
  else: cfg.apiKey

proc startWebLogin*(s: var AiSession): string =
  s.pushMsg "Paste an API token with :login <token> (OAuth loopback not implemented)."
  "awaiting token paste"

proc setApiKey*(s: var AiSession, key: string) =
  s.cfg.apiKey = key
  s.pushMsg "API key set (" & $key.len & " chars)"

proc setProvider*(s: var AiSession, name: string) =
  case name.toLowerAscii
  of "openai", "openai-compat":
    s.cfg.provider = apkOpenAiCompat
    if s.cfg.baseUrl.len == 0 or "anthropic" in s.cfg.baseUrl or "11434" in s.cfg.baseUrl:
      s.cfg.baseUrl = "https://api.openai.com/v1"
  of "anthropic":
    s.cfg.provider = apkAnthropic
    s.cfg.baseUrl = "https://api.anthropic.com"
  of "ollama", "local":
    s.cfg.provider = apkOllama
    s.cfg.baseUrl = "http://127.0.0.1:11434/v1"
  else:
    s.pushMsg "unknown provider: " & name & " (openai|anthropic|ollama)"
    return
  s.pushMsg "provider: " & name

proc setModel*(s: var AiSession, model: string) =
  if model.len == 0:
    s.pushMsg "usage: :model <id>  (current: " & s.cfg.model & ")"
    return
  s.cfg.model = model
  s.pushMsg "model: " & model

proc clearChat*(s: var AiSession) =
  s.messages = @["Chat cleared."]
  s.contextCache.clear()
  s.scroll = 0
  s.saveSession()

proc refreshProjectMemory*(s: var AiSession, root: string) =
  s.workspace = root
  s.projectMemory = loadProjectMemory(root)
  s.rebuildSystem()
  let n = if s.projectMemory.len > 0: "loaded" else: "none found"
  s.pushMsg "project memory: " & n

proc buildMessages(
    systemPrompt, transcriptCtx, userPrompt, ragCtx, bufferCtx: string
): JsonNode =
  result = newJArray()
  result.add %*{"role": "system", "content": systemPrompt}
  if transcriptCtx.len > 0:
    result.add %*{"role": "system", "content": "Session context:\n" & transcriptCtx}
  if ragCtx.len > 0:
    result.add %*{"role": "system", "content": ragCtx}
  if bufferCtx.len > 0:
    result.add %*{"role": "system", "content": "Current buffer / selection:\n" & bufferCtx}
  result.add %*{"role": "user", "content": userPrompt}

proc chatOpenAiOnce(
    cfg: AiConfig,
    messages: JsonNode,
    withTools: bool,
    stats: var TokenStats,
): JsonNode =
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & authHeader(cfg),
  })
  var body = %*{
    "model": cfg.model,
    "messages": messages,
    "temperature": 0.2,
  }
  if withTools:
    body["tools"] = openaiToolDefs()
  let url = cfg.baseUrl.strip(leading = false, trailing = true, chars = {'/'}) &
    "/chat/completions"
  let resp = client.postContent(url, $body)
  let j = parseJson(resp)
  if j.hasKey("usage"):
    stats.promptTokens += j["usage"]{"prompt_tokens"}.getInt
    stats.completionTokens += j["usage"]{"completion_tokens"}.getInt
  result = j["choices"][0]["message"]

proc chatAnthropic(
    cfg: AiConfig,
    systemPrompt, userPrompt, ragCtx, bufferCtx: string,
): string =
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "x-api-key": authHeader(cfg),
    "anthropic-version": "2023-06-01",
  })
  var system = systemPrompt
  if ragCtx.len > 0: system.add "\n" & ragCtx
  if bufferCtx.len > 0: system.add "\n" & bufferCtx
  let body = %*{
    "model": if cfg.model.len > 0: cfg.model else: "claude-3-5-haiku-latest",
    "max_tokens": 2048,
    "system": system,
    "messages": [%*{"role": "user", "content": userPrompt}],
  }
  let resp = client.postContent(cfg.baseUrl.strip(chars = {'/'}) & "/v1/messages", $body)
  let j = parseJson(resp)
  result = j["content"][0]["text"].getStr

proc cancelled(cancel: ptr Atomic[bool]): bool =
  cancel != nil and cancel[].load

proc runToolLoop(
    args: AiJobArgs,
    stats: var TokenStats,
): string =
  var messages = buildMessages(
    args.systemPrompt, args.transcriptCtx, args.prompt, args.ragCtx, args.bufferCtx
  )
  const maxRounds = 8
  for round in 0 ..< maxRounds:
    if cancelled(args.cancel):
      return "(cancelled)"
    let msg = chatOpenAiOnce(args.cfg, messages, args.useTools, stats)
    messages.add msg
    if not msg.hasKey("tool_calls") or msg["tool_calls"].len == 0:
      return msg{"content"}.getStr
    for tc in msg["tool_calls"]:
      if cancelled(args.cancel):
        return "(cancelled)"
      let id = tc{"id"}.getStr
      let name = tc["function"]{"name"}.getStr
      let argStr = tc["function"]{"arguments"}.getStr
      aiEventChan.send AiJobEvent(kind: ajTool, text: name)
      let tr = dispatchTool(args.workspace, name, argStr, args.allowDangerous)
      if tr.needsApproval:
        aiEventChan.send AiJobEvent(kind: ajChunk, text: tr.output)
      messages.add %*{
        "role": "tool",
        "tool_call_id": id,
        "content": tr.output,
      }
  "(tool loop limit reached)"

proc executeAsk(args: AiJobArgs): tuple[answer: string, stats: TokenStats] =
  var stats: TokenStats
  var answer: string
  case args.cfg.provider
  of apkAnthropic:
    answer = chatAnthropic(
      args.cfg, args.systemPrompt, args.prompt, args.ragCtx, args.bufferCtx
    )
  else:
    if args.useTools:
      answer = runToolLoop(args, stats)
    else:
      let msgs = buildMessages(
        args.systemPrompt, args.transcriptCtx, args.prompt, args.ragCtx, args.bufferCtx
      )
      let msg = chatOpenAiOnce(args.cfg, msgs, false, stats)
      answer = msg{"content"}.getStr
  if answer.len == 0:
    answer = "(empty response)"
  (answer, stats)

proc aiWorker(args: AiJobArgs) {.thread.} =
  ensureAiChan()
  try:
    let (answer, stats) = executeAsk(args)
    discard stats
    aiEventChan.send AiJobEvent(kind: ajDone, text: answer)
  except CatchableError as e:
    aiEventChan.send AiJobEvent(kind: ajError, text: e.msg)

proc startAskAsync*(s: var AiSession, prompt, bufferCtx: string) =
  if s.busy:
    s.pushMsg "AI busy — Esc cancels between tool rounds."
    return
  if not s.hasCredentials:
    s.pushMsg "No credentials. Use :login <token> or set TAI_API_KEY."
    return
  ensureAiChan()
  if gAiThreadLive:
    joinThread(gAiThread)
    gAiThreadLive = false

  var ragCtx = ""
  if s.rag.chunks.len > 0:
    ragCtx = formatContext(retrieve(s.rag, prompt))

  s.pushMsg "user: " & prompt
  s.busy = true
  s.cancelRequested.store(false)

  let args = AiJobArgs(
    cfg: s.cfg,
    systemPrompt: s.systemPrompt,
    prompt: prompt,
    bufferCtx: bufferCtx,
    ragCtx: ragCtx,
    workspace: s.workspace,
    useTools: s.useTools,
    allowDangerous: s.allowDangerous,
    cancel: addr s.cancelRequested,
    transcriptCtx: s.contextCache.contextBlock(),
  )
  createThread(gAiThread, aiWorker, args)
  gAiThreadLive = true

proc pollAiEvents*(s: var AiSession): bool =
  ## Drain channel; returns true if a job finished.
  ensureAiChan()
  result = false
  while true:
    let (ok, ev) = aiEventChan.tryRecv()
    if not ok: break
    case ev.kind
    of ajTool:
      s.pushMsg "tool: " & ev.text
    of ajChunk:
      s.pushMsg ev.text
    of ajDone:
      for line in ev.text.splitLines():
        s.pushMsg "assistant: " & line
      s.contextCache.appendTurn("user", "(see transcript)")
      s.contextCache.appendTurn("assistant", ev.text)
      s.saveSession()
      s.busy = false
      if gAiThreadLive:
        joinThread(gAiThread)
        gAiThreadLive = false
      result = true
    of ajError:
      s.pushMsg "AI error: " & ev.text
      s.busy = false
      if gAiThreadLive:
        joinThread(gAiThread)
        gAiThreadLive = false
      result = true
    of ajNone:
      discard

proc requestCancel*(s: var AiSession) =
  s.cancelRequested.store(true)
  s.pushMsg "(cancel requested)"

proc visibleTranscript*(s: AiSession, maxLines: int): seq[string] =
  if maxLines <= 0 or s.messages.len == 0:
    return @[]
  let endIdx = max(0, s.messages.high - max(0, s.scroll))
  let startIdx = max(0, endIdx - maxLines + 1)
  if startIdx > endIdx: return @[]
  s.messages[startIdx .. endIdx]

proc ask*(
    s: var AiSession,
    userPrompt: string,
    bufferCtx = "",
    runShell = "",
): string =
  ## Synchronous ask (tests / scripting). Prefer startAskAsync in the TUI.
  var extra = bufferCtx
  if runShell.len > 0:
    let r = runWithRtk(runShell)
    s.stats.rtkSavedTokens += r.savedTokens
    extra.add "\nCommand output"
    if r.usedRtk: extra.add " (rtk)"
    extra.add ":\n" & r.output

  if not s.hasCredentials:
    return "No credentials. Use :login <token> or set TAI_API_KEY."

  var ragCtx = ""
  if s.rag.chunks.len > 0:
    ragCtx = formatContext(retrieve(s.rag, userPrompt))

  s.busy = true
  s.cancelRequested.store(false)
  s.pushMsg "user: " & userPrompt
  try:
    let args = AiJobArgs(
      cfg: s.cfg,
      systemPrompt: s.systemPrompt,
      prompt: userPrompt,
      bufferCtx: extra,
      ragCtx: ragCtx,
      workspace: s.workspace,
      useTools: s.useTools,
      allowDangerous: s.allowDangerous,
      cancel: addr s.cancelRequested,
      transcriptCtx: s.contextCache.contextBlock(),
    )
    let (answer, stats) = executeAsk(args)
    s.stats.promptTokens += stats.promptTokens
    s.stats.completionTokens += stats.completionTokens
    for line in answer.splitLines():
      s.pushMsg "assistant: " & line
    s.contextCache.appendTurn("user", userPrompt)
    s.contextCache.appendTurn("assistant", answer)
    s.saveSession()
    result = answer
  except CatchableError as e:
    result = "AI error: " & e.msg
    s.pushMsg result
  finally:
    s.busy = false
