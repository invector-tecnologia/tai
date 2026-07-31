## Built-in agent tools + mode gating.

import std/[os, strutils, osproc, json]
import ../config
import ./rtk

type
  ToolResult* = object
    ok*: bool
    output*: string
    needsApproval*: bool
    pendingName*: string
    pendingArgs*: string

proc truncateOut(s: string, limit = 12_000): string =
  if s.len <= limit: s
  else: s[0 ..< limit] & "\n… truncated (" & $s.len & " bytes)"

proc toolReadFile*(root, path: string): ToolResult =
  let p =
    if path.isAbsolute: path
    else: root / path
  if not fileExists(p):
    return ToolResult(ok: false, output: "file not found: " & p)
  try:
    let info = getFileInfo(p)
    if info.size > 256_000:
      return ToolResult(ok: false, output: "file too large (>256KB): " & p)
    ToolResult(ok: true, output: truncateOut(readFile(p)))
  except CatchableError as e:
    ToolResult(ok: false, output: e.msg)

proc toolListDir*(root, path: string): ToolResult =
  let p =
    if path.len == 0: root
    elif path.isAbsolute: path
    else: root / path
  if not dirExists(p):
    return ToolResult(ok: false, output: "not a directory: " & p)
  var lines: seq[string]
  for kind, fp in walkDir(p):
    let name = fp.extractFilename
    if name.startsWith('.'): continue
    case kind
    of pcDir, pcLinkToDir: lines.add name & "/"
    else: lines.add name
  ToolResult(ok: true, output: truncateOut(lines.join("\n")))

proc toolGrep*(root, pattern: string, glob = ""): ToolResult =
  if pattern.len == 0:
    return ToolResult(ok: false, output: "empty pattern")
  let rg = findExe("rg")
  var cmd: string
  if rg.len > 0:
    cmd = "rg -n --no-heading -m 40"
    if glob.len > 0: cmd.add " -g " & quoteShell(glob)
    cmd.add " " & quoteShell(pattern) & " " & quoteShell(root)
  else:
    cmd = "grep -RIn -m 40 " & quoteShell(pattern) & " " & quoteShell(root)
  try:
    let (outp, code) = execCmdEx(cmd)
    discard code
    ToolResult(ok: true, output: truncateOut(if outp.len > 0: outp else: "(no matches)"))
  except CatchableError as e:
    ToolResult(ok: false, output: e.msg)

proc toolWriteFile*(root, path, content: string, allowed: bool): ToolResult =
  if not allowed:
    return ToolResult(
      ok: false,
      needsApproval: true,
      pendingName: "write_file",
      pendingArgs: path,
      output: "write_file blocked — switch to :agent mode",
    )
  let p =
    if path.isAbsolute: path
    else: root / path
  try:
    let parent = parentDir(p)
    if parent.len > 0: createDir(parent)
    writeFile(p, content)
    ToolResult(ok: true, output: "wrote " & p & " (" & $content.len & " bytes)")
  except CatchableError as e:
    ToolResult(ok: false, output: e.msg)

proc toolShell*(cmd: string, allowed: bool): ToolResult =
  if not allowed:
    return ToolResult(
      ok: false,
      needsApproval: true,
      pendingName: "shell",
      pendingArgs: cmd,
      output: "shell blocked — switch to :agent mode",
    )
  if cmd.len == 0:
    return ToolResult(ok: false, output: "empty command")
  let r = runWithRtk(cmd)
  let note = if r.usedRtk: " (rtk)" else: ""
  ToolResult(ok: true, output: truncateOut(r.output) & note)

proc toolAllowed*(mode: AiMode, name: string): bool =
  case mode
  of amAsk:
    false
  of amPlan:
    name in ["read_file", "list_dir", "grep"]
  of amAgent:
    true

proc openaiToolDefs*(mode: AiMode): JsonNode =
  let all = parseJson("""
[
  {"type":"function","function":{"name":"read_file","description":"Read a text file from the workspace","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
  {"type":"function","function":{"name":"list_dir","description":"List files in a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}}},
  {"type":"function","function":{"name":"grep","description":"Search workspace for a pattern","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string"}},"required":["pattern"]}}},
  {"type":"function","function":{"name":"write_file","description":"Write content to a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
  {"type":"function","function":{"name":"shell","description":"Run a shell command in the workspace","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},
  {"type":"function","function":{"name":"git_status","description":"Show git status","parameters":{"type":"object","properties":{},"required":[]}}},
  {"type":"function","function":{"name":"invoke_skill","description":"Load a skill by name into context","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}
]
""")
  if mode == amAsk:
    return newJArray()
  result = newJArray()
  for t in all:
    let n = t["function"]{"name"}.getStr
    if toolAllowed(mode, n) or (mode == amAgent and n in ["git_status", "invoke_skill"]):
      if mode == amPlan and n notin ["read_file", "list_dir", "grep"]:
        continue
      result.add t

proc dispatchTool*(
    root, name, argsJson: string,
    mode: AiMode,
    skillBody = "",
): ToolResult =
  if not toolAllowed(mode, name) and name notin ["git_status", "invoke_skill"]:
    return ToolResult(ok: false, output: "tool '" & name & "' not allowed in " & modeName(mode) & " mode")
  if mode == amPlan and name in ["write_file", "shell"]:
    return ToolResult(ok: false, output: "plan mode is read-only")
  var args = newJObject()
  try:
    if argsJson.len > 0:
      args = parseJson(argsJson)
  except CatchableError:
    return ToolResult(ok: false, output: "invalid tool args JSON")
  let allowDangerous = mode == amAgent
  case name
  of "read_file":
    toolReadFile(root, args{"path"}.getStr)
  of "list_dir":
    toolListDir(root, args{"path"}.getStr)
  of "grep":
    toolGrep(root, args{"pattern"}.getStr, args{"glob"}.getStr)
  of "write_file":
    toolWriteFile(root, args{"path"}.getStr, args{"content"}.getStr, allowDangerous)
  of "shell":
    toolShell(args{"command"}.getStr, allowDangerous)
  of "git_status":
    let g = findExe("git")
    if g.len == 0:
      return ToolResult(ok: false, output: "git not found")
    let (outp, _) = execCmdEx(quoteShell(g) & " status -sb", workingDir = root)
    ToolResult(ok: true, output: truncateOut(outp))
  of "invoke_skill":
    if skillBody.len > 0:
      ToolResult(ok: true, output: skillBody)
    else:
      ToolResult(ok: false, output: "skill not found: " & args{"name"}.getStr)
  else:
    # MCP tools are handled by caller with mcp_ prefix
    ToolResult(ok: false, output: "unknown tool: " & name)
