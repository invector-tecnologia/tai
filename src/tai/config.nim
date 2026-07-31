## User preferences loaded from ~/.config/tai/config.toml

import std/[os, strutils]
import parsetoml

type
  FileTreeSide* = enum
    ftsLeft
    ftsRight

  KeymapStyle* = enum
    kmHelix
    kmVim

  AiProviderKind* = enum
    apkOpenAiCompat
    apkAnthropic
    apkGoogle
    apkOllama

  AiConfig* = object
    provider*: AiProviderKind
    apiKey*: string
    baseUrl*: string
    model*: string
    authToken*: string

  Config* = object
    fileTreeSide*: FileTreeSide
    keymap*: KeymapStyle
    theme*: string
    outlinesVisible*: bool
    previewMode*: bool
    sidePanelWidth*: int
    bottomPanelHeight*: int
    workspace*: string
    ai*: AiConfig

proc defaultConfig*(): Config =
  Config(
    fileTreeSide: ftsLeft,
    keymap: kmHelix,
    theme: "default",
    outlinesVisible: true,
    previewMode: false,
    sidePanelWidth: 28,
    bottomPanelHeight: 8,
    workspace: getCurrentDir(),
    ai: AiConfig(
      provider: apkOpenAiCompat,
      apiKey: getEnv("TAI_API_KEY", ""),
      baseUrl: getEnv("TAI_BASE_URL", "https://api.openai.com/v1"),
      model: getEnv("TAI_MODEL", "gpt-4o-mini"),
      authToken: "",
    ),
  )

proc configPath*(): string =
  getConfigDir() / "tai" / "config.toml"

proc parseSide(s: string): FileTreeSide =
  case s.toLowerAscii
  of "right": ftsRight
  else: ftsLeft

proc parseKeymap(s: string): KeymapStyle =
  case s.toLowerAscii
  of "vim": kmVim
  else: kmHelix

proc parseProvider(s: string): AiProviderKind =
  case s.toLowerAscii
  of "anthropic": apkAnthropic
  of "google": apkGoogle
  of "ollama": apkOllama
  else: apkOpenAiCompat

proc loadConfig*(path = configPath()): Config =
  result = defaultConfig()
  if not fileExists(path):
    return
  let t = parsetoml.parseFile(path)
  if t.hasKey("file_tree_side"):
    result.fileTreeSide = parseSide(t["file_tree_side"].getStr)
  if t.hasKey("keymap"):
    result.keymap = parseKeymap(t["keymap"].getStr)
  if t.hasKey("theme"):
    result.theme = t["theme"].getStr
  if t.hasKey("outlines_visible"):
    result.outlinesVisible = t["outlines_visible"].getBool
  if t.hasKey("preview_mode"):
    result.previewMode = t["preview_mode"].getBool
  if t.hasKey("side_panel_width"):
    result.sidePanelWidth = t["side_panel_width"].getInt
  if t.hasKey("bottom_panel_height"):
    result.bottomPanelHeight = t["bottom_panel_height"].getInt
  if t.hasKey("workspace"):
    result.workspace = t["workspace"].getStr
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

proc saveConfig*(cfg: Config, path = configPath()) =
  createDir(parentDir(path))
  let side =
    case cfg.fileTreeSide
    of ftsLeft: "left"
    of ftsRight: "right"
  let keymap =
    case cfg.keymap
    of kmHelix: "helix"
    of kmVim: "vim"
  let provider =
    case cfg.ai.provider
    of apkOpenAiCompat: "openai"
    of apkAnthropic: "anthropic"
    of apkGoogle: "google"
    of apkOllama: "ollama"
  let body = """
file_tree_side = "$#"
keymap = "$#"
theme = "$#"
outlines_visible = $#
preview_mode = $#
side_panel_width = $#
bottom_panel_height = $#
workspace = "$#"

[ai]
provider = "$#"
api_key = "$#"
base_url = "$#"
model = "$#"
auth_token = "$#"
""" % [
    side, keymap, cfg.theme, $cfg.outlinesVisible, $cfg.previewMode,
    $cfg.sidePanelWidth, $cfg.bottomPanelHeight, cfg.workspace,
    provider, cfg.ai.apiKey, cfg.ai.baseUrl, cfg.ai.model, cfg.ai.authToken,
  ]
  writeFile(path, body)
