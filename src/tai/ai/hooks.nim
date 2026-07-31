## Lifecycle hooks (pre_tool / post_tool / pre_ask).

import std/[os, osproc, strutils]
import ../config

proc runHook*(hooks: seq[HookConfig], event, toolName, toolArgs: string): tuple[ok: bool, output: string] =
  result.ok = true
  result.output = ""
  for h in hooks:
    if h.event.toLowerAscii != event.toLowerAscii: continue
    if h.command.len == 0: continue
    putEnv("TAI_TOOL", toolName)
    putEnv("TAI_ARGS", toolArgs)
    putEnv("TAI_HOOK_EVENT", event)
    try:
      let (outp, code) = execCmdEx(h.command)
      if outp.len > 0:
        result.output.add outp
      if code != 0 and event.startsWith("pre"):
        result.ok = false
        result.output.add "\nhook blocked (" & h.command & " exit " & $code & ")"
        return
    except CatchableError as e:
      if event.startsWith("pre"):
        result.ok = false
        result.output = e.msg
        return
