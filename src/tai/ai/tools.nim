## Built-in agent tools: read, search, write, shell (optional RTK).

import std/[os, strutils, osproc, json]
import ./rtk

type
  ToolPermission* = enum
    tpReadOnly   ## read_file, grep, list_dir only
    tpAsk        ## writes/shell need allowDangerous
    tpAllowAll   ## all tools

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
      output: "write_file blocked — enable with :agent on",
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
      output: "shell blocked — enable with :agent on",
    )
  if cmd.len == 0:
    return ToolResult(ok: false, output: "empty command")
  let r = runWithRtk(cmd)
  let note = if r.usedRtk: " (rtk)" else: ""
  ToolResult(ok: true, output: truncateOut(r.output) & note)

proc openaiToolDefs*(): JsonNode =
  parseJson("""
[
  {"type":"function","function":{"name":"read_file","description":"Read a text file from the workspace","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
  {"type":"function","function":{"name":"list_dir","description":"List files in a directory","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}}},
  {"type":"function","function":{"name":"grep","description":"Search workspace for a pattern","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string"}},"required":["pattern"]}}},
  {"type":"function","function":{"name":"write_file","description":"Write content to a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
  {"type":"function","function":{"name":"shell","description":"Run a shell command in the workspace","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}
]
""")

proc dispatchTool*(
    root, name, argsJson: string,
    allowDangerous: bool,
): ToolResult =
  var args = newJObject()
  try:
    if argsJson.len > 0:
      args = parseJson(argsJson)
  except CatchableError:
    return ToolResult(ok: false, output: "invalid tool args JSON")
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
  else:
    ToolResult(ok: false, output: "unknown tool: " & name)
