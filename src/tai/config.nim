## User preferences loaded from ~/.config/tai/config.toml

import std/[os, strutils, sequtils]
import parsetoml

type
  FileTreeSide* = enum
    ftsLeft
    ftsRight

  AiProviderKind* = enum
    apkOpenAiCompat
    apkAnthropic
    apkOllama

  AiMode* = enum
    amAsk
    amPlan
    amAgent

  KeymapStyle* = enum
    kmHelix
    kmVim

  ThemeId* = enum
    thTokyoNight
    thCatppuccinMocha
    thGruvboxDark

  HighlightEngine* = enum
    heAuto
    heRegex
    heTreeSitter

  AiConfig* = object
    provider*: AiProviderKind
    apiKey*: string
    baseUrl*: string
    model*: string
    authToken*: string
    mode*: AiMode
    oauthClientId*: string
    deviceAuthUrl*: string
    tokenUrl*: string

  AudioConfig* = object
    url*: string
    autoplay*: bool

  McpServerConfig* = object
    name*: string
    command*: string
    args*: seq[string]

  HookConfig* = object
    event*: string
    command*: string

  Config* = object
    fileTreeSide*: FileTreeSide
    outlinesVisible*: bool
    filesVisible*: bool
    previewMode*: bool
    sidePanelWidth*: int
    bottomPanelHeight*: int
    workspace*: string
    theme*: ThemeId
    keymap*: KeymapStyle
    highlightEngine*: HighlightEngine
    ai*: AiConfig
    audio*: AudioConfig
    mcpServers*: seq[McpServerConfig]
    hooks*: seq[HookConfig]

proc defaultConfig*(): Config =
  Config(
    fileTreeSide: ftsLeft,
    outlinesVisible: true,
    filesVisible: true,
    previewMode: false,
    sidePanelWidth: 28,
    bottomPanelHeight: 8,
    workspace: getCurrentDir(),
    theme: thTokyoNight,
    keymap: kmHelix,
    highlightEngine: heAuto,
    ai: AiConfig(
      provider: apkOpenAiCompat,
      apiKey: getEnv("TAI_API_KEY", ""),
      baseUrl: getEnv("TAI_BASE_URL", "https://api.openai.com/v1"),
      model: getEnv("TAI_MODEL", "gpt-4o-mini"),
      authToken: "",
      mode: amAsk,
      oauthClientId: "",
      deviceAuthUrl: "",
      tokenUrl: "",
    ),
    audio: AudioConfig(
      url: getEnv("TAI_AUDIO_URL", ""),
      autoplay: false,
    ),
    mcpServers: @[],
    hooks: @[],
  )

proc configPath*(): string =
  getConfigDir() / "tai" / "config.toml"

proc parseSide(s: string): FileTreeSide =
  case s.toLowerAscii
  of "right": ftsRight
  else: ftsLeft

proc parseProvider(s: string): AiProviderKind =
  case s.toLowerAscii
  of "anthropic": apkAnthropic
  of "ollama", "local": apkOllama
  else: apkOpenAiCompat

proc parseMode*(s: string): AiMode =
  case s.toLowerAscii
  of "plan": amPlan
  of "agent": amAgent
  else: amAsk

proc modeName*(m: AiMode): string =
  case m
  of amAsk: "ask"
  of amPlan: "plan"
  of amAgent: "agent"

proc parseTheme*(s: string): ThemeId =
  case s.toLowerAscii.replace("-", "_")
  of "catppuccin", "catppuccin_mocha", "mocha": thCatppuccinMocha
  of "gruvbox", "gruvbox_dark": thGruvboxDark
  else: thTokyoNight

proc themeName*(t: ThemeId): string =
  case t
  of thTokyoNight: "tokyo_night"
  of thCatppuccinMocha: "catppuccin_mocha"
  of thGruvboxDark: "gruvbox_dark"

proc parseKeymap*(s: string): KeymapStyle =
  case s.toLowerAscii
  of "vim": kmVim
  else: kmHelix

proc parseHighlightEngine*(s: string): HighlightEngine =
  case s.toLowerAscii
  of "regex": heRegex
  of "treesitter", "tree_sitter", "ts": heTreeSitter
  else: heAuto

proc loadConfig*(path = configPath()): Config =
  result = defaultConfig()
  if not fileExists(path):
    return
  let t = parsetoml.parseFile(path)
  if t.hasKey("file_tree_side"):
    result.fileTreeSide = parseSide(t["file_tree_side"].getStr)
  if t.hasKey("outlines_visible"):
    result.outlinesVisible = t["outlines_visible"].getBool
  if t.hasKey("files_visible"):
    result.filesVisible = t["files_visible"].getBool
  if t.hasKey("preview_mode"):
    result.previewMode = t["preview_mode"].getBool
  if t.hasKey("side_panel_width"):
    result.sidePanelWidth = t["side_panel_width"].getInt
  if t.hasKey("bottom_panel_height"):
    result.bottomPanelHeight = t["bottom_panel_height"].getInt
  if t.hasKey("workspace"):
    result.workspace = t["workspace"].getStr
  if t.hasKey("theme"):
    result.theme = parseTheme(t["theme"].getStr)
  if t.hasKey("keymap"):
    result.keymap = parseKeymap(t["keymap"].getStr)
  if t.hasKey("highlight_engine"):
    result.highlightEngine = parseHighlightEngine(t["highlight_engine"].getStr)
  if t.hasKey("ai"):
    let ai = t["ai"]
    if ai.hasKey("provider"):
      result.ai.provider = parseProvider(ai["provider"].getStr)
    if ai.hasKey("api_key"):
      result.ai.apiKey = ai["api_key"].getStr
    if ai.hasKey("base_url"):
      result.ai.baseUrl = ai["base_url"].getStr
    if ai.hasKey("model"):
      result.ai.model = ai["model"].getStr
    if ai.hasKey("auth_token"):
      result.ai.authToken = ai["auth_token"].getStr
    if ai.hasKey("mode"):
      result.ai.mode = parseMode(ai["mode"].getStr)
    if ai.hasKey("oauth_client_id"):
      result.ai.oauthClientId = ai["oauth_client_id"].getStr
    if ai.hasKey("device_auth_url"):
      result.ai.deviceAuthUrl = ai["device_auth_url"].getStr
    if ai.hasKey("token_url"):
      result.ai.tokenUrl = ai["token_url"].getStr
  if t.hasKey("audio"):
    let audio = t["audio"]
    if audio.hasKey("url"):
      result.audio.url = audio["url"].getStr
    if audio.hasKey("autoplay"):
      result.audio.autoplay = audio["autoplay"].getBool
  if t.hasKey("mcp") and t["mcp"].hasKey("servers"):
    for s in t["mcp"]["servers"].getElems:
      var srv = McpServerConfig(name: s{"name"}.getStr, command: s{"command"}.getStr)
      if s.hasKey("args"):
        for a in s["args"].getElems:
          srv.args.add a.getStr
      if srv.name.len > 0 and srv.command.len > 0:
        result.mcpServers.add srv
  # Alternative: array of tables under [[mcp.servers]] via parsetoml may appear as mcp.servers
  if t.hasKey("hooks"):
    for h in t["hooks"].getElems:
      result.hooks.add HookConfig(event: h{"event"}.getStr, command: h{"command"}.getStr)

proc saveConfig*(cfg: Config, path = configPath()) =
  createDir(parentDir(path))
  let side =
    case cfg.fileTreeSide
    of ftsLeft: "left"
    of ftsRight: "right"
  let provider =
    case cfg.ai.provider
    of apkOpenAiCompat: "openai"
    of apkAnthropic: "anthropic"
    of apkOllama: "ollama"
  let keymap =
    case cfg.keymap
    of kmHelix: "helix"
    of kmVim: "vim"
  let hl =
    case cfg.highlightEngine
    of heAuto: "auto"
    of heRegex: "regex"
    of heTreeSitter: "treesitter"
  var body = """
file_tree_side = "$#"
outlines_visible = $#
files_visible = $#
preview_mode = $#
side_panel_width = $#
bottom_panel_height = $#
workspace = "$#"
theme = "$#"
keymap = "$#"
highlight_engine = "$#"

[ai]
provider = "$#"
api_key = "$#"
base_url = "$#"
model = "$#"
auth_token = "$#"
mode = "$#"
oauth_client_id = "$#"
device_auth_url = "$#"
token_url = "$#"

[audio]
url = "$#"
autoplay = $#
""" % [
    side, $cfg.outlinesVisible, $cfg.filesVisible, $cfg.previewMode,
    $cfg.sidePanelWidth, $cfg.bottomPanelHeight, cfg.workspace,
    themeName(cfg.theme), keymap, hl,
    provider, cfg.ai.apiKey, cfg.ai.baseUrl, cfg.ai.model, cfg.ai.authToken,
    modeName(cfg.ai.mode), cfg.ai.oauthClientId, cfg.ai.deviceAuthUrl, cfg.ai.tokenUrl,
    cfg.audio.url, $cfg.audio.autoplay,
  ]
  for s in cfg.mcpServers:
    body.add "\n[[mcp.servers]]\n"
    body.add "name = \"" & s.name & "\"\n"
    body.add "command = \"" & s.command & "\"\n"
    body.add "args = [" & s.args.mapIt("\"" & it & "\"").join(", ") & "]\n"
  for h in cfg.hooks:
    body.add "\n[[hooks]]\n"
    body.add "event = \"" & h.event & "\"\n"
    body.add "command = \"" & h.command & "\"\n"
  writeFile(path, body)
