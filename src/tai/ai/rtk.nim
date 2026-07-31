## RTK (Rust Token Killer) integration for compressing shell tool output.

import std/[os, osproc, strutils]
import ./cache

type
  RtkResult* = object
    output*: string
    rawBytes*: int
    compactBytes*: int
    savedTokens*: int
    usedRtk*: bool

proc rtkAvailable*(): bool =
  findExe("rtk").len > 0

proc runWithRtk*(cmd: string): RtkResult =
  ## Prefer `rtk <cmd>` when installed; otherwise run raw and estimate no savings.
  let rawCmd = cmd
  try:
    if rtkAvailable():
      let (outp, code) = execCmdEx("rtk " & rawCmd)
      discard code
      # Also measure raw for savings estimate
      let (rawOut, _) = execCmdEx(rawCmd)
      result.output = outp
      result.rawBytes = rawOut.len
      result.compactBytes = outp.len
      result.savedTokens = max(0, estimateTokens(rawOut) - estimateTokens(outp))
      result.usedRtk = true
    else:
      let (outp, code) = execCmdEx(rawCmd)
      discard code
      result.output = outp
      result.rawBytes = outp.len
      result.compactBytes = outp.len
      result.savedTokens = 0
      result.usedRtk = false
  except CatchableError as e:
    result.output = "error: " & e.msg
    result.usedRtk = false

proc formatGain*(stats: TokenStats): string =
  "tokens in=$# out=$# saved=$# rtk=$#" % [
    $stats.promptTokens, $stats.completionTokens, $stats.savedTokens, $stats.rtkSavedTokens,
  ]
