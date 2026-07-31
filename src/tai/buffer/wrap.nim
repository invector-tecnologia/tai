## Soft-wrap view rows for the editor (display-only; buffer unchanged).

import std/[strutils, unicode]
import ../ui/utf8clip
import tatui/core/unicodewidth

type
  VisualRow* = object
    srcLine*: int
    startByte*, endByte*: int
    ## True when the source line may use horizontal scroll (no soft-wrap).
    hard*: bool

proc isCodeFenceLine*(line: string): bool =
  ## Use ASCII strip — unicode.strip crashes on invalid UTF-8 (e.g. PDF bytes).
  strutils.strip(line, trailing = false).startsWith("```")

proc isMarkdownTableLine*(line: string): bool =
  let t = strutils.strip(line)
  if not t.startsWith('|'):
    return false
  var bars = 0
  for c in t:
    if c == '|':
      inc bars
  bars >= 2

proc shouldSoftWrap*(line: string, inCodeFence: bool): bool =
  ## Prose/lists wrap; tables and fenced code do not.
  if inCodeFence:
    return false
  if isCodeFenceLine(line):
    return false
  if isMarkdownTableLine(line):
    return false
  true

proc wrapLineSegments(line: string, width: int): seq[tuple[a, b: int]] =
  ## Split `line` into [start,end) byte ranges each fitting `width` columns.
  if width <= 0:
    return @[(0, line.len)]
  if displayWidth(line) <= width:
    return @[(0, line.len)]
  var start = 0
  while start < line.len:
    var cols = 0
    var i = start
    var lastSpace = -1
    while i < line.len:
      let n = safeRuneLen(line, i)
      let w = runeDisplayWidth(line.runeAt(i))
      if w > 0 and cols + w > width:
        break
      if line[i] == ' ':
        lastSpace = i + n
      cols += w
      i += n
    if i == start:
      i = start + safeRuneLen(line, start)
    elif i < line.len and lastSpace > start:
      i = lastSpace
    result.add (start, i)
    start = i
    while start < line.len and line[start] == ' ':
      inc start
  if result.len == 0:
    result.add (0, line.len)

proc buildVisualRows*(lines: openArray[string], width: int): seq[VisualRow] =
  ## Build soft-wrapped visual rows for the viewport width.
  var inFence = false
  for li, line in lines:
    if isCodeFenceLine(line):
      inFence = not inFence
      result.add VisualRow(srcLine: li, startByte: 0, endByte: line.len, hard: true)
      continue
    if not shouldSoftWrap(line, inFence):
      result.add VisualRow(srcLine: li, startByte: 0, endByte: line.len, hard: true)
    else:
      for s in wrapLineSegments(line, width):
        result.add VisualRow(srcLine: li, startByte: s.a, endByte: s.b, hard: false)

proc visualIndexAt*(rows: openArray[VisualRow], srcLine, byteCol: int): int =
  ## Visual row containing `(srcLine, byteCol)`.
  if rows.len == 0:
    return 0
  let col = max(0, byteCol)
  var lastForLine = -1
  for i, r in rows:
    if r.srcLine != srcLine:
      continue
    lastForLine = i
    if col >= r.startByte and col < r.endByte:
      return i
    if col == r.endByte and r.startByte == r.endByte:
      return i
  if lastForLine >= 0:
    # col at/past end of line → last visual row for that source line
    return lastForLine
  if srcLine < rows[0].srcLine:
    return 0
  rows.high
