## AI provider: streaming, modes, tools, skills, hooks, MCP, sessions.

import std/[httpclient, json, strutils, os, atomics, options, tables, streams]
import std/typedthreads
import ../config
import ./cache
import ./rag
import ./rtk
import ./tools
import ./sse
import ./skills
import ./hooks
import ./mcp
import ./oauth

type
  AiJobKind* = enum
    ajNone
    ajDone
    ajError
    ajChunk
    ajTool
    ajStreamDelta

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
    mode*: AiMode
    cancel*: ptr Atomic[bool]
    transcriptCtx*: string
    hooks*: seq[HookConfig]
    skillBodies*: Table[string, string]
    mcpToolJson*: JsonNode ## extra tools array or empty

  AiSession* = object
    cfg*: AiConfig
    messages*: seq[string]
    input*: string
    busy*: bool
    streaming*: bool
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
    mode*: AiMode
    skills*: Table[string, Skill]
    hooks*: seq[HookConfig]
    mcp*: McpClient
    deviceCode*: string
    oauthPolling*: bool

var aiEventChan: Channel[AiJobEvent]
var aiChanReady: bool
var gAiThread: Thread[AiJobArgs]
var gAiThreadLive: bool

proc ensureAiChan() =
  if not aiChanReady:
    aiEventChan.open(128)
    aiChanReady = true

proc pushMsg*(s: var AiSession, line: string) =
  s.messages.add line
  if s.messages.len > 400:
    s.messages = s.messages[^300 .. ^1]

proc appendStreamDelta*(s: var AiSession, delta: string) =
  if delta.len == 0: return
  s.streaming = true
  if s.messages.len > 0 and s.messages[^1].startsWith("assistant: "):
    s.messages[^1].add delta
  else:
    s.messages.add "assistant: " & delta

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

proc modeSystemExtra(mode: AiMode): string =
  case mode
  of amAsk:
    "Mode: ASK — answer questions; do not call tools."
  of amPlan:
    "Mode: PLAN — research with read-only tools only. Produce a numbered plan. Do not edit files or run shell."
  of amAgent:
    "Mode: AGENT — you may read, edit files, and run shell when needed."

proc baseSystemPrompt(mode: AiMode): string =
  """
You are Tai's embedded coding assistant inside a TUI editor.
Be concise. Prefer actionable edits. Use tools when they help and the mode allows.
Respect open buffer context and project instruction files.
""".strip() & "\n" & modeSystemExtra(mode)

proc rebuildSystem*(s: var AiSession) =
  var parts = @[baseSystemPrompt(s.mode)]
  if s.projectMemory.len > 0:
    parts.add "Project instructions:\n" & s.projectMemory
  let sk = skillsPromptBlock(s.skills)
  if sk.len > 0:
    parts.add sk
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

proc setMode*(s: var AiSession, mode: AiMode) =
  s.mode = mode
  s.cfg.mode = mode
  s.rebuildSystem()
  s.pushMsg "mode: " & modeName(mode)

proc initAiSession*(cfg: AiConfig, cacheDir, workspace: string, hooks: seq[HookConfig] = @[],
    mcpServers: seq[McpServerConfig] = @[]): AiSession =
  ensureAiChan()
  result.cfg = cfg
  result.workspace = workspace
  result.mode = cfg.mode
  result.hooks = hooks
  result.promptCache = initPromptCache()
  result.contextCache = initContextCache()
  result.responseCache = initResponseCache(cacheDir / "responses.json")
  result.sessionPath = cacheDir / "session.json"
  result.projectMemory = loadProjectMemory(workspace)
  result.skills = discoverSkills(workspace)
  result.mcp = initMcpClient(mcpServers)
  let (access, _) = loadCredentials()
  if access.len > 0 and result.cfg.authToken.len == 0:
    result.cfg.authToken = access
  result.rebuildSystem()
  result.loadSession()
  if result.messages.len == 0:
    result.messages = @[
      "Tai AI ready. :ask | :plan | :agent | :login | :mcp list | :git status",
    ]
  result.cancelRequested.store(false)

proc hasCredentials*(s: AiSession): bool =
  s.cfg.apiKey.len > 0 or s.cfg.authToken.len > 0 or s.cfg.provider == apkOllama

proc authHeader(cfg: AiConfig): string =
  if cfg.authToken.len > 0: cfg.authToken
  else: cfg.apiKey

proc startWebLogin*(s: var AiSession): string =
  let started = startDeviceFlow(s.cfg.deviceAuthUrl, s.cfg.oauthClientId)
  if started.ok:
    s.deviceCode = started.deviceCode
    s.oauthPolling = true
    s.pushMsg started.message
    s.pushMsg "Polling for authorization…"
    return started.message
  s.pushMsg started.message
  s.pushMsg "Or paste a token: :login <token>"
  started.message

proc setApiKey*(s: var AiSession, key: string) =
  s.cfg.apiKey = key
  s.cfg.authToken = key
  saveCredentials(key, "")
  s.oauthPolling = false
  s.pushMsg "API key set (" & $key.len & " chars)"

proc pollOAuth*(s: var AiSession) =
  if not s.oauthPolling or s.deviceCode.len == 0: return
  if s.cfg.tokenUrl.len == 0: return
  let tok = pollDeviceToken(s.cfg.tokenUrl, s.cfg.oauthClientId, s.deviceCode)
  if tok.ok:
    s.cfg.authToken = tok.accessToken
    saveCredentials(tok.accessToken, tok.refreshToken)
    s.oauthPolling = false
    s.pushMsg "OAuth login successful"
  elif tok.message notin ["authorization_pending", "slow_down"]:
    s.oauthPolling = false
    s.pushMsg "OAuth: " & tok.message

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
  s.streaming = false
  s.saveSession()

proc refreshProjectMemory*(s: var AiSession, root: string) =
  s.workspace = root
  s.projectMemory = loadProjectMemory(root)
  s.skills = discoverSkills(root)
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

proc cancelled(cancel: ptr Atomic[bool]): bool =
  cancel != nil and cancel[].load

proc mergeToolDefs(mode: AiMode, mcpExtra: JsonNode): JsonNode =
  result = openaiToolDefs(mode)
  if mcpExtra != nil and mcpExtra.kind == JArray and mode == amAgent:
    for t in mcpExtra:
      result.add t

proc chatOpenAiOnce(
    cfg: AiConfig,
    messages: JsonNode,
    mode: AiMode,
    mcpExtra: JsonNode,
    stats: var TokenStats,
    cancel: ptr Atomic[bool],
    streamText: bool,
): JsonNode =
  let client = newHttpClient(timeout = 120_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & authHeader(cfg),
  })
  let tools = mergeToolDefs(mode, mcpExtra)
  var body = %*{
    "model": cfg.model,
    "messages": messages,
    "temperature": 0.2,
  }
  if tools.len > 0:
    body["tools"] = tools
  let wantStream = streamText and tools.len == 0
  if wantStream:
    body["stream"] = %true
  let url = cfg.baseUrl.strip(leading = false, trailing = true, chars = {'/'}) &
    "/chat/completions"

  if not wantStream:
    let resp = client.postContent(url, $body)
    if cancelled(cancel):
      return %*{"role": "assistant", "content": "(cancelled)"}
    let j = parseJson(resp)
    if j.hasKey("usage"):
      stats.promptTokens += j["usage"]{"prompt_tokens"}.getInt
      stats.completionTokens += j["usage"]{"completion_tokens"}.getInt
    return j["choices"][0]["message"]

  # Streaming path (text-only)
  let response = client.request(url, httpMethod = HttpPost, body = $body)
  var content = ""
  var lineBuf = ""
  let stream = response.bodyStream
  while not stream.atEnd:
    if cancelled(cancel):
      return %*{"role": "assistant", "content": content & "\n(cancelled)"}
    let ch = stream.readChar()
    if ch == '\n':
      let opt = parseSseDataLine(lineBuf)
      lineBuf = ""
      if opt.isSome:
        let delta = deltaContent(opt.get)
        if delta.len > 0:
          content.add delta
          aiEventChan.send AiJobEvent(kind: ajStreamDelta, text: delta)
    else:
      lineBuf.add ch
  if lineBuf.len > 0:
    let opt = parseSseDataLine(lineBuf)
    if opt.isSome:
      let delta = deltaContent(opt.get)
      if delta.len > 0:
        content.add delta
        aiEventChan.send AiJobEvent(kind: ajStreamDelta, text: delta)
  %*{"role": "assistant", "content": content}

proc chatAnthropicStream(
    cfg: AiConfig,
    systemPrompt, userPrompt, ragCtx, bufferCtx: string,
    cancel: ptr Atomic[bool],
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
    "stream": true,
    "system": system,
    "messages": [%*{"role": "user", "content": userPrompt}],
  }
  let url = cfg.baseUrl.strip(chars = {'/'}) & "/v1/messages"
  let response = client.request(url, httpMethod = HttpPost, body = $body)
  var content = ""
  var lineBuf = ""
  let stream = response.bodyStream
  while not stream.atEnd:
    if cancelled(cancel):
      return content & "\n(cancelled)"
    let ch = stream.readChar()
    if ch == '\n':
      let line = lineBuf.strip()
      lineBuf = ""
      if line.startsWith("data:"):
        let payload = line[5 .. ^1].strip()
        if payload.len == 0 or payload == "[DONE]": continue
        try:
          let j = parseJson(payload)
          if j{"type"}.getStr == "content_block_delta":
            let d = j["delta"]{"text"}.getStr
            if d.len > 0:
              content.add d
              aiEventChan.send AiJobEvent(kind: ajStreamDelta, text: d)
        except CatchableError:
          discard
    else:
      lineBuf.add ch
  content

proc resolveSkill(args: AiJobArgs, name: string): string =
  let key = name.toLowerAscii
  if args.skillBodies.hasKey(key):
    return args.skillBodies[key]
  ""

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
    let msg = chatOpenAiOnce(
      args.cfg, messages, args.mode, args.mcpToolJson, stats, args.cancel, streamText = false
    )
    messages.add msg
    if not msg.hasKey("tool_calls") or msg["tool_calls"].len == 0:
      let text = msg{"content"}.getStr
      if text.len > 0:
        aiEventChan.send AiJobEvent(kind: ajStreamDelta, text: text)
      return text
    for tc in msg["tool_calls"]:
      if cancelled(args.cancel):
        return "(cancelled)"
      let id = tc{"id"}.getStr
      let name = tc["function"]{"name"}.getStr
      let argStr = tc["function"]{"arguments"}.getStr
      aiEventChan.send AiJobEvent(kind: ajTool, text: name)
      let pre = runHook(args.hooks, "pre_tool", name, argStr)
      var outp: string
      if not pre.ok:
        outp = pre.output
      elif name.startsWith("mcp_"):
        outp = "MCP call must be handled on main session" # filled via sync path
        # Worker cannot easily share mcp client; skip with message
        outp = "mcp tools require main-thread; use built-in tools in agent worker for now"
      elif name == "invoke_skill":
        var argsJ = newJObject()
        try: argsJ = parseJson(argStr) except CatchableError: discard
        outp = resolveSkill(args, argsJ{"name"}.getStr)
        if outp.len == 0: outp = "skill not found"
      else:
        let tr = dispatchTool(args.workspace, name, argStr, args.mode)
        outp = tr.output
      discard runHook(args.hooks, "post_tool", name, argStr)
      messages.add %*{
        "role": "tool",
        "tool_call_id": id,
        "content": outp,
      }
  "(tool loop limit reached)"

proc executeAsk(args: AiJobArgs): tuple[answer: string, stats: TokenStats] =
  var stats: TokenStats
  var answer: string
  let pre = runHook(args.hooks, "pre_ask", "", args.prompt)
  if not pre.ok:
    return (pre.output, stats)
  case args.cfg.provider
  of apkAnthropic:
    answer = chatAnthropicStream(
      args.cfg, args.systemPrompt, args.prompt, args.ragCtx, args.bufferCtx, args.cancel
    )
  else:
    if args.mode != amAsk:
      answer = runToolLoop(args, stats)
    else:
      let msgs = buildMessages(
        args.systemPrompt, args.transcriptCtx, args.prompt, args.ragCtx, args.bufferCtx
      )
      let msg = chatOpenAiOnce(
        args.cfg, msgs, amAsk, nil, stats, args.cancel, streamText = true
      )
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
    s.pushMsg "AI busy — Esc cancels."
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
  s.streaming = false
  s.cancelRequested.store(false)

  var skillBodies = initTable[string, string]()
  for k, sk in s.skills:
    skillBodies[k] = "# Skill: " & sk.name & "\n" & sk.body

  s.mcp.ensureStarted()
  let mcpDefs = if s.mode == amAgent: s.mcp.mcpToolDefs() else: newJArray()

  let args = AiJobArgs(
    cfg: s.cfg,
    systemPrompt: s.systemPrompt,
    prompt: prompt,
    bufferCtx: bufferCtx,
    ragCtx: ragCtx,
    workspace: s.workspace,
    mode: s.mode,
    cancel: addr s.cancelRequested,
    transcriptCtx: s.contextCache.contextBlock(),
    hooks: s.hooks,
    skillBodies: skillBodies,
    mcpToolJson: mcpDefs,
  )
  createThread(gAiThread, aiWorker, args)
  gAiThreadLive = true

proc pollAiEvents*(s: var AiSession): bool =
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
    of ajStreamDelta:
      s.appendStreamDelta(ev.text)
    of ajDone:
      if not s.streaming:
        for line in ev.text.splitLines():
          s.pushMsg "assistant: " & line
      s.streaming = false
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
      s.streaming = false
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
  result = s.messages[startIdx .. endIdx]
  if s.busy and s.streaming and result.len > 0:
    result[^1].add "▌"

proc ask*(
    s: var AiSession,
    userPrompt: string,
    bufferCtx = "",
    runShell = "",
): string =
  var extra = bufferCtx
  if runShell.len > 0:
    let r = runWithRtk(runShell)
    s.stats.rtkSavedTokens += r.savedTokens
    extra.add "\nCommand output:\n" & r.output
  if not s.hasCredentials:
    return "No credentials."
  var ragCtx = ""
  if s.rag.chunks.len > 0:
    ragCtx = formatContext(retrieve(s.rag, userPrompt))
  s.busy = true
  s.cancelRequested.store(false)
  s.pushMsg "user: " & userPrompt
  try:
    var skillBodies = initTable[string, string]()
    for k, sk in s.skills:
      skillBodies[k] = sk.body
    let args = AiJobArgs(
      cfg: s.cfg,
      systemPrompt: s.systemPrompt,
      prompt: userPrompt,
      bufferCtx: extra,
      ragCtx: ragCtx,
      workspace: s.workspace,
      mode: s.mode,
      cancel: addr s.cancelRequested,
      transcriptCtx: s.contextCache.contextBlock(),
      hooks: s.hooks,
      skillBodies: skillBodies,
      mcpToolJson: newJArray(),
    )
    let (answer, stats) = executeAsk(args)
    s.stats.promptTokens += stats.promptTokens
    s.stats.completionTokens += stats.completionTokens
    for line in answer.splitLines():
      s.pushMsg "assistant: " & line
    result = answer
  except CatchableError as e:
    result = "AI error: " & e.msg
    s.pushMsg result
  finally:
    s.busy = false
