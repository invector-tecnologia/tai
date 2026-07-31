## Lightweight Markdown/HTML → terminal preview lines.

import std/[os, strutils]

proc renderMarkdownPreview*(source: seq[string]): seq[string] =
  var inFence = false
  for line in source:
    let t = line.strip(trailing = false)
    if t.startsWith("```"):
      inFence = not inFence
      result.add if inFence: "┌─ code ─" else: "└────────"
      continue
    if inFence:
      result.add "│ " & line
      continue
    if t.startsWith("### "):
      result.add "▸ " & t[4 .. ^1]
    elif t.startsWith("## "):
      result.add "▸▸ " & t[3 .. ^1]
    elif t.startsWith("# "):
      result.add "══ " & t[2 .. ^1].toUpperAscii & " ══"
    elif t.startsWith("> "):
      result.add "│ " & t[2 .. ^1]
    elif t.startsWith("- ") or t.startsWith("* "):
      result.add "  • " & t[2 .. ^1]
    elif t.startsWith("---"):
      result.add "────────────"
    else:
      var s = line
      s = s.replace("**", "")
      s = s.replace("__", "")
      s = s.replace("`", "")
      result.add s
  if result.len == 0:
    result = @[""]

proc renderHtmlPreview*(source: seq[string]): seq[string] =
  for line in source:
    var outLine = ""
    var i = 0
    var inTag = false
    while i < line.len:
      let c = line[i]
      if c == '<':
        inTag = true
      elif c == '>':
        inTag = false
      elif not inTag:
        outLine.add c
      inc i
    let t = outLine.strip()
    if t.len > 0:
      result.add t
  if result.len == 0:
    result = @[""]

proc canPreview*(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii
  ext in [".md", ".markdown", ".html", ".htm"]
