## Native clipboard via platform tools (xclip / wl-clipboard / pbcopy).

import std/[os, osproc, strutils]

proc copyToClipboard*(text: string): bool =
  try:
    when defined(macosx):
      let (outp, code) = execCmdEx("pbcopy", input = text)
      discard outp
      return code == 0
    else:
      if getEnv("WAYLAND_DISPLAY").len > 0:
        let (outp, code) = execCmdEx("wl-copy", input = text)
        discard outp
        return code == 0
      else:
        let (outp, code) = execCmdEx("xclip -selection clipboard", input = text)
        discard outp
        return code == 0
  except CatchableError:
    return false

proc pasteFromClipboard*(): string =
  try:
    when defined(macosx):
      result = execProcess("pbpaste", options = {poUsePath, poStdErrToStdOut})
    else:
      if getEnv("WAYLAND_DISPLAY").len > 0:
        result = execProcess("wl-paste", args = ["-n"], options = {poUsePath, poStdErrToStdOut})
      else:
        result = execProcess(
          "xclip",
          args = ["-selection", "clipboard", "-o"],
          options = {poUsePath, poStdErrToStdOut},
        )
    result = result.strip(leading = false, trailing = true, chars = {'\0'})
  except CatchableError:
    result = ""
