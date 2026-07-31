## Line-oriented document buffer with undo and dirty tracking.

import std/[os, strutils]

type
  Cursor* = object
    row*, col*: int

  Selection* = object
    active*: bool
    anchor*: Cursor
    head*: Cursor

  EditOp* = object
    beforeLines*: seq[string]
    afterLines*: seq[string]
    beforeCursor*: Cursor
    afterCursor*: Cursor

  Document* = object
    path*: string
    lines*: seq[string]
    cursor*: Cursor
    selection*: Selection
    dirty*: bool
    undoStack*: seq[EditOp]
    redoStack*: seq[EditOp]
    bytesLoaded*: int
    lineEnding*: string
    previewMode*: bool
    readonly*: bool

proc emptyDocument*(path = ""): Document =
  Document(
    path: path,
    lines: @[""],
    cursor: Cursor(row: 0, col: 0),
    lineEnding: "\n",
  )

proc fromText*(text: string, path = ""): Document =
  result = emptyDocument(path)
  var le = "\n"
  if text.contains("\r\n"):
    le = "\r\n"
  result.lineEnding = le
  result.lines = text.splitLines()
  if result.lines.len == 0:
    result.lines = @[""]
  result.bytesLoaded = text.len

proc text*(d: Document): string =
  d.lines.join(d.lineEnding)

proc lineCount*(d: Document): int =
  d.lines.len

proc clampCursor*(d: Document, c: Cursor): Cursor =
  result.row = clamp(c.row, 0, max(0, d.lines.high))
  let maxCol = if d.lines.len == 0: 0 else: d.lines[result.row].len
  result.col = clamp(c.col, 0, maxCol)

proc setCursor*(d: var Document, c: Cursor) =
  d.cursor = d.clampCursor(c)
  d.selection.active = false

proc clearSelection*(d: var Document) =
  d.selection.active = false

proc beginSelection*(d: var Document) =
  d.selection.active = true
  d.selection.anchor = d.cursor
  d.selection.head = d.cursor

proc updateSelectionHead*(d: var Document) =
  if d.selection.active:
    d.selection.head = d.cursor

proc normalizedSelection*(d: Document): tuple[a, b: Cursor] =
  let a = d.selection.anchor
  let b = d.selection.head
  if a.row < b.row or (a.row == b.row and a.col <= b.col):
    (a, b)
  else:
    (b, a)

proc selectedText*(d: Document): string =
  if not d.selection.active:
    return ""
  let (a, b) = d.normalizedSelection()
  if a.row == b.row:
    return d.lines[a.row][a.col ..< b.col]
  var parts: seq[string]
  parts.add d.lines[a.row][a.col .. ^1]
  for r in (a.row + 1) ..< b.row:
    parts.add d.lines[r]
  parts.add d.lines[b.row][0 ..< b.col]
  parts.join(d.lineEnding)

proc pushUndo(d: var Document, before, after: seq[string], bc, ac: Cursor) =
  d.undoStack.add EditOp(
    beforeLines: before, afterLines: after, beforeCursor: bc, afterCursor: ac
  )
  d.redoStack.setLen(0)
  if d.undoStack.len > 200:
    d.undoStack.delete(0)

proc replaceAll*(d: var Document, newLines: seq[string], newCursor: Cursor) =
  let before = d.lines
  let bc = d.cursor
  d.lines = if newLines.len == 0: @[""] else: newLines
  d.cursor = d.clampCursor(newCursor)
  d.dirty = true
  d.pushUndo(before, d.lines, bc, d.cursor)
  d.clearSelection()

proc insertText*(d: var Document, s: string) =
  if d.readonly:
    return
  let before = d.lines
  let bc = d.cursor
  var row = d.cursor.row
  var col = d.cursor.col
  let parts = s.splitLines()
  if parts.len == 1:
    var line = d.lines[row]
    line.insert(parts[0], col)
    d.lines[row] = line
    d.cursor = Cursor(row: row, col: col + parts[0].len)
  else:
    let line = d.lines[row]
    let left = line[0 ..< col]
    let right = line[col .. ^1]
    d.lines[row] = left & parts[0]
    for i in 1 ..< parts.high:
      d.lines.insert(parts[i], row + i)
    d.lines.insert(parts[^1] & right, row + parts.high)
    d.cursor = Cursor(row: row + parts.high, col: parts[^1].len)
  d.dirty = true
  d.pushUndo(before, d.lines, bc, d.cursor)
  d.clearSelection()

proc deleteSelection*(d: var Document) =
  if d.readonly or not d.selection.active:
    return
  let before = d.lines
  let bc = d.cursor
  let (a, b) = d.normalizedSelection()
  if a.row == b.row:
    var line = d.lines[a.row]
    line.delete(a.col ..< b.col)
    d.lines[a.row] = line
  else:
    let left = d.lines[a.row][0 ..< a.col]
    let right = d.lines[b.row][b.col .. ^1]
    d.lines[a.row] = left & right
    for _ in a.row + 1 .. b.row:
      if a.row + 1 < d.lines.len:
        d.lines.delete(a.row + 1)
  d.cursor = a
  d.dirty = true
  d.pushUndo(before, d.lines, bc, d.cursor)
  d.clearSelection()

proc backspace*(d: var Document) =
  if d.readonly:
    return
  if d.selection.active:
    d.deleteSelection()
    return
  if d.cursor.row == 0 and d.cursor.col == 0:
    return
  let before = d.lines
  let bc = d.cursor
  if d.cursor.col > 0:
    var line = d.lines[d.cursor.row]
    line.delete(d.cursor.col - 1 .. d.cursor.col - 1)
    d.lines[d.cursor.row] = line
    dec d.cursor.col
  else:
    let prevLen = d.lines[d.cursor.row - 1].len
    d.lines[d.cursor.row - 1].add d.lines[d.cursor.row]
    d.lines.delete(d.cursor.row)
    d.cursor = Cursor(row: d.cursor.row - 1, col: prevLen)
  d.dirty = true
  d.pushUndo(before, d.lines, bc, d.cursor)

proc deleteForward*(d: var Document) =
  if d.readonly:
    return
  if d.selection.active:
    d.deleteSelection()
    return
  let row = d.cursor.row
  let col = d.cursor.col
  if row >= d.lines.high and col >= d.lines[row].len:
    return
  let before = d.lines
  let bc = d.cursor
  if col < d.lines[row].len:
    var line = d.lines[row]
    line.delete(col .. col)
    d.lines[row] = line
  else:
    d.lines[row].add d.lines[row + 1]
    d.lines.delete(row + 1)
  d.dirty = true
  d.pushUndo(before, d.lines, bc, d.cursor)

proc newline*(d: var Document) =
  d.insertText("\n")

proc selectAll*(d: var Document) =
  if d.lines.len == 0:
    return
  d.selection.active = true
  d.selection.anchor = Cursor(row: 0, col: 0)
  d.selection.head = Cursor(row: d.lines.high, col: d.lines[^1].len)
  d.cursor = d.selection.head

proc undo*(d: var Document) =
  if d.undoStack.len == 0:
    return
  let op = d.undoStack.pop()
  d.redoStack.add op
  d.lines = op.beforeLines
  d.cursor = op.beforeCursor
  d.dirty = true
  d.clearSelection()

proc redo*(d: var Document) =
  if d.redoStack.len == 0:
    return
  let op = d.redoStack.pop()
  d.undoStack.add op
  d.lines = op.afterLines
  d.cursor = op.afterCursor
  d.dirty = true
  d.clearSelection()

proc displayName*(d: Document): string =
  let base =
    if d.path.len == 0: "[scratch]"
    else: d.path.extractFilename
  if d.dirty: base & " *" else: base
