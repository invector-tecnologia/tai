## Application state, layout, draw loop, and input handling.

import std/[os, strutils, options, times]
from std/unicode import toUTF8, Rune
import tatui
import tatui/core/[rect, color, style]

import ./config
import ./buffer/[document, tabs]
import ./fs/[io, clipboard, watcher]
import ./commands/dispatch
import ./editor/context_menu
import ./highlight/engine
import ./outline/extract
import ./preview/render
import ./ai/[provider, rag, rtk]

type
  FocusPanel* = enum
    fpEditor
    fpFileTree
    fpOutlines
    fpCommand
    fpAi

  PanelRects* = object
    top*, left*, center*, right*, bottom*: Rect

  App* = object
    cfg*: Config
    tabs*: TabManager
    cwd*: string
    fileEntries*: seq[DirEntry]
    fileState*: ListState
    outlineItems*: seq[OutlineItem]
    outlineState*: ListState
    scrollY*: int
    scrollX*: int
    focus*: FocusPanel
    commandMode*: bool
    commandLine*: string
    statusMsg*: string
    statusUntil*: float
    quit*: bool
    menu*: ContextMenu
    mouseSelecting*: bool
    watcher*: FileWatcher
    ai*: AiSession
    lastFrameMs*: float
    panelRects*: PanelRects
    treeExpanded*: bool

proc setStatus*(app: var App, msg: string, secs = 3.0) =
  app.statusMsg = msg
  app.statusUntil = epochTime() + secs

proc refreshFileTree*(app: var App) =
  app.fileEntries = listDirEntries(app.cwd)
  if app.fileState.selected.isNone and app.fileEntries.len > 0:
    app.fileState.select(0)

proc refreshOutlines*(app: var App) =
  app.outlineItems = extractOutlines(app.tabs.current)
  if app.outlineItems.len > 0:
    app.outlineState.select(0)

proc openPath*(app: var App, path: string) =
  let loaded = loadFile(path)
  if loaded.ok:
    app.tabs.openDoc(loaded.doc)
    app.watcher.watch(path)
    app.scrollY = 0
    app.refreshOutlines()
    app.setStatus("opened " & path.extractFilename & " in " &
      $loaded.elapsedMs.int & "ms")
  else:
    var doc = emptyDocument(path)
    app.tabs.openDoc(doc)
    app.setStatus(loaded.error)

proc initApp*(cfg: Config): App =
  result.cfg = cfg
  result.tabs = initTabManager()
  result.cwd = if dirExists(cfg.workspace): cfg.workspace else: getCurrentDir()
  result.menu = initContextMenu()
  result.watcher = initFileWatcher()
  result.ai = initAiSession(cfg.ai, getConfigDir() / "tai" / "cache")
  result.focus = fpEditor
  result.treeExpanded = true
  result.refreshFileTree()
  result.refreshOutlines()
  result.setStatus("Tai ready — :help")

proc computeLayout*(app: var App, area: Rect): PanelRects =
  let topH = 1
  let bottomH = max(3, app.cfg.bottomPanelHeight)
  let sideW =
    if app.cfg.outlinesVisible: max(12, app.cfg.sidePanelWidth)
    else: max(12, app.cfg.sidePanelWidth)
  let rows = area.split(Vertical, @[length(topH), fill(1), length(bottomH)])
  result.top = rows[0]
  result.bottom = rows[2]
  let mid = rows[1]
  if app.cfg.outlinesVisible:
    let cols =
      if app.cfg.fileTreeSide == ftsLeft:
        mid.split(Horizontal, @[length(sideW), fill(1), length(sideW)])
      else:
        mid.split(Horizontal, @[length(sideW), fill(1), length(sideW)])
    if app.cfg.fileTreeSide == ftsLeft:
      result.left = cols[0]
      result.center = cols[1]
      result.right = cols[2]
    else:
      # tree on right, outlines on left
      result.left = cols[0]
      result.center = cols[1]
      result.right = cols[2]
  else:
    let cols =
      if app.cfg.fileTreeSide == ftsLeft:
        mid.split(Horizontal, @[length(sideW), fill(1)])
      else:
        mid.split(Horizontal, @[fill(1), length(sideW)])
    if app.cfg.fileTreeSide == ftsLeft:
      result.left = cols[0]
      result.center = cols[1]
      result.right = rect(0, 0, 0, 0)
    else:
      result.left = rect(0, 0, 0, 0)
      result.center = cols[0]
      result.right = cols[1]
  app.panelRects = result

proc fileTreeArea(app: App): Rect =
  if app.cfg.fileTreeSide == ftsLeft: app.panelRects.left
  else: app.panelRects.right

proc outlinesArea(app: App): Rect =
  if not app.cfg.outlinesVisible: rect(0, 0, 0, 0)
  elif app.cfg.fileTreeSide == ftsLeft: app.panelRects.right
  else: app.panelRects.left

proc drawContextMenu(app: var App, f: var Frame) =
  if not app.menu.visible:
    return
  let w = 16
  let h = app.menu.items.len
  var x = app.menu.x
  var y = app.menu.y
  if x + w > f.area.right: x = max(0, f.area.right - w)
  if y + h > f.area.bottom: y = max(0, f.area.bottom - h)
  let area = rect(x, y, w, h)
  app.menu.area = area
  let blk = initBlock(borders = AllBorders, title = " Edit ", borderType = btRounded)
  f.renderWidget(blk, area)
  let inner = blk.inner(area)
  for i, item in app.menu.items:
    let st =
      if i == app.menu.selected:
        style(fg = some(Black), bg = some(Cyan), mods = {mBold})
      else:
        defaultStyle()
    discard f.buf[].setStringN(inner.left, inner.top + i, " " & item.label, st, inner.width.int)

proc drawEditor(app: var App, f: var Frame, area: Rect) =
  var doc = app.tabs.current
  let title =
    if doc.previewMode: " Preview "
    else: " " & doc.displayName() & " "
  let blk = initBlock(title = title, borders = AllBorders)
  f.renderWidget(blk, area)
  let inner = blk.inner(area)
  if inner.isEmpty:
    return

  var lines = doc.lines
  if doc.previewMode and canPreview(doc.path):
    let ext = doc.path.splitFile.ext.toLowerAscii
    if ext in [".md", ".markdown"]:
      lines = renderMarkdownPreview(doc.lines)
    else:
      lines = renderHtmlPreview(doc.lines)

  let lang = detectLang(doc.path)
  let viewH = inner.height.int
  let viewW = inner.width.int
  if app.scrollY > max(0, lines.len - viewH):
    app.scrollY = max(0, lines.len - viewH)

  let endLine = min(lines.high, app.scrollY + viewH - 1)
  let highlighted =
    if doc.previewMode: @[]
    else: highlightRange(lang, lines, app.scrollY, endLine)

  for row in 0 ..< viewH:
    let lineIdx = app.scrollY + row
    if lineIdx > lines.high:
      break
    let y = inner.top + row
    let line = lines[lineIdx]
    let visible =
      if app.scrollX >= line.len: ""
      else: line[app.scrollX .. ^1]
    if doc.previewMode or highlighted.len == 0:
      discard f.buf[].setStringN(inner.left, y, visible, defaultStyle(), viewW)
    else:
      let hl = highlighted[lineIdx - app.scrollY]
      var x = inner.left
      for span in hl.spans:
        if span.finish <= app.scrollX: continue
        let start = max(span.start, app.scrollX)
        if start >= span.finish: continue
        let slice = line[start ..< span.finish]
        let st = tokenStyle(span.kind)
        let written = f.buf[].setStringN(x, y, slice, st, inner.right - x)
        x += written
        if x >= inner.right: break
    if doc.selection.active and not doc.previewMode:
      let (a, b) = doc.normalizedSelection()
      if lineIdx >= a.row and lineIdx <= b.row:
        discard f.buf[].setStringN(inner.left, y, "▌", style(fg = some(Cyan)), 1)

  # cursor
  if app.focus == fpEditor and not doc.previewMode and not app.commandMode:
    let cy = doc.cursor.row - app.scrollY
    let cx = doc.cursor.col - app.scrollX
    if cy >= 0 and cy < viewH and cx >= 0 and cx < viewW:
      f.setCursor(pos(inner.left + cx, inner.top + cy))

proc drawSideList(
    f: var Frame, area: Rect, title: string, labels: seq[string], state: var ListState
) =
  var items: seq[ListItem]
  for lab in labels:
    items.add listItem(lab)
  let blk = some(initBlock(title = title, borders = AllBorders))
  let lst = list(
    items,
    blk = blk,
    highlightStyle = style(fg = some(Black), bg = some(Blue)),
    highlightSymbol = "› ",
  )
  f.renderStateful(lst, area, state)

proc draw*(app: var App, f: var Frame) =
  let t0 = cpuTime()
  let layout = app.computeLayout(f.area)

  # Top: tabs
  let titles = app.tabs.titles()
  let tabBar = tabs(
    titles,
    selected = app.tabs.active,
    highlightStyle = style(fg = some(Black), bg = some(Cyan), mods = {mBold}),
    divider = " │ ",
  )
  f.renderWidget(tabBar, layout.top)

  # File tree
  let treeArea = app.fileTreeArea()
  if not treeArea.isEmpty:
    var labels: seq[string]
    labels.add ".. (parent)"
    for e in app.fileEntries:
      labels.add e.name
    var st = app.fileState
    drawSideList(f, treeArea, " Files ", labels, st)
    app.fileState = st

  # Outlines
  let outArea = app.outlinesArea()
  if not outArea.isEmpty:
    var labels: seq[string]
    for o in app.outlineItems:
      labels.add repeat("  ", o.depth) & o.label
    var st = app.outlineState
    drawSideList(f, outArea, " Outlines ", labels, st)
    app.outlineState = st

  # Center editor
  app.drawEditor(f, layout.center)

  # Bottom: AI + command
  let bottomBlk = initBlock(
    title = " AI / :cmd  [" & formatGain(app.ai.stats) & "] ",
    borders = AllBorders,
  )
  f.renderWidget(bottomBlk, layout.bottom)
  let bInner = bottomBlk.inner(layout.bottom)
  if not bInner.isEmpty:
    let msg =
      if app.ai.messages.len > 0: app.ai.messages[^1]
      else: ""
    let clipped =
      if msg.len > bInner.width.int: msg[0 ..< bInner.width.int]
      else: msg
    discard f.buf[].setStringN(bInner.left, bInner.top, clipped, defaultStyle(), bInner.width.int)
    let prompt =
      if app.commandMode: ":" & app.commandLine & "█"
      elif app.focus == fpAi: "ai> " & app.ai.input & "█"
      else:
        let st =
          if epochTime() < app.statusUntil: app.statusMsg
          else: "Ctrl-Q quit │ : commands │ Tab focus │ mouse supported"
        st
    if bInner.height.int > 1:
      discard f.buf[].setStringN(
        bInner.left, bInner.top + 1, prompt, style(fg = some(Yellow)), bInner.width.int
      )

  app.drawContextMenu(f)
  app.lastFrameMs = (cpuTime() - t0) * 1000

proc ensureCursorVisible(app: var App, areaH: int) =
  let row = app.tabs.current.cursor.row
  if row < app.scrollY:
    app.scrollY = row
  elif row >= app.scrollY + areaH:
    app.scrollY = row - areaH + 1

proc handleAiCommand(app: var App, cmd: string) =
  let parts = strutils.splitWhitespace(cmd)
  if parts.len == 0: return
  case parts[0].toLowerAscii
  of "login":
    if parts.len >= 2:
      app.ai.setApiKey(parts[1 .. ^1].join(" "))
      app.cfg.ai = app.ai.cfg
      saveConfig(app.cfg)
      app.setStatus("logged in (api key)")
    else:
      discard app.ai.startWebLogin()
      app.setStatus("web auth started — :login <token>")
  of "provider":
    if parts.len >= 2:
      app.ai.setProvider(parts[1])
      app.cfg.ai = app.ai.cfg
      saveConfig(app.cfg)
  of "rag":
    if parts.len >= 2 and parts[1] == "reindex":
      app.ai.rag = reindex(app.cwd)
      app.setStatus("RAG indexed " & $app.ai.rag.chunks.len & " chunks")
    else:
      app.setStatus("usage: :rag reindex")
  of "ai":
    let prompt = if parts.len > 1: parts[1 .. ^1].join(" ") else: ""
    if prompt.len == 0:
      app.focus = fpAi
      app.setStatus("AI focus — type message, Enter to send")
    else:
      let bufCtx = app.tabs.current.text()
      let clipped = if bufCtx.len > 4000: bufCtx[0 ..< 4000] else: bufCtx
      discard app.ai.ask(prompt, clipped)
  else:
    discard

proc runCommand(app: var App, line: string) =
  var doc = app.tabs.docs[app.tabs.active]
  var ctx = CommandContext(cfg: addr app.cfg, doc: addr doc, status: "")
  let r = dispatchCommand(ctx, line)
  app.tabs.docs[app.tabs.active] = doc
  if r.message.startsWith("AI_CMD:"):
    app.handleAiCommand(r.message["AI_CMD:".len .. ^1])
  elif r.ok:
    if r.message.len > 0:
      app.setStatus(r.message)
    if r.quit:
      app.quit = true
    app.refreshOutlines()
    saveConfig(app.cfg)
  else:
    app.setStatus(r.message)

proc moveCursor(app: var App, drow, dcol: int, selecting: bool) =
  var doc = app.tabs.current
  if selecting and not doc.selection.active:
    doc.beginSelection()
  elif not selecting:
    doc.clearSelection()
  doc.cursor = doc.clampCursor(Cursor(row: doc.cursor.row + drow, col: doc.cursor.col + dcol))
  if selecting:
    doc.updateSelectionHead()
  app.tabs.docs[app.tabs.active] = doc
  let h = max(1, app.panelRects.center.height.int - 2)
  app.ensureCursorVisible(h)

proc handleEditorKey(app: var App, key: KeyEvent) =
  var doc = app.tabs.current
  let selecting = kmShift in key.mods
  case key.code
  of kcLeft:
    app.moveCursor(0, -1, selecting)
  of kcRight:
    app.moveCursor(0, 1, selecting)
  of kcUp:
    app.moveCursor(-1, 0, selecting)
  of kcDown:
    app.moveCursor(1, 0, selecting)
  of kcHome:
    doc.cursor.col = 0
    if selecting: doc.updateSelectionHead() else: doc.clearSelection()
    app.tabs.docs[app.tabs.active] = doc
  of kcEnd:
    doc.cursor.col = doc.lines[doc.cursor.row].len
    if selecting: doc.updateSelectionHead() else: doc.clearSelection()
    app.tabs.docs[app.tabs.active] = doc
  of kcPageUp:
    app.moveCursor(-(app.panelRects.center.height.int), 0, selecting)
  of kcPageDown:
    app.moveCursor(app.panelRects.center.height.int, 0, selecting)
  of kcBackspace:
    doc.backspace()
    app.tabs.docs[app.tabs.active] = doc
    app.refreshOutlines()
  of kcDelete:
    doc.deleteForward()
    app.tabs.docs[app.tabs.active] = doc
    app.refreshOutlines()
  of kcEnter:
    doc.newline()
    app.tabs.docs[app.tabs.active] = doc
    app.refreshOutlines()
  of kcTab:
    doc.insertText("  ")
    app.tabs.docs[app.tabs.active] = doc
  of kcChar:
    if kmCtrl in key.mods:
      let ch = key.rune.toUTF8.toLowerAscii
      case ch
      of "c":
        let t = if doc.selection.active: doc.selectedText() else: ""
        if t.len > 0 and copyToClipboard(t):
          app.setStatus("copied")
      of "x":
        let t = if doc.selection.active: doc.selectedText() else: ""
        if t.len > 0:
          discard copyToClipboard(t)
          doc.deleteSelection()
          app.tabs.docs[app.tabs.active] = doc
          app.setStatus("cut")
      of "v":
        let t = pasteFromClipboard()
        if t.len > 0:
          if doc.selection.active: doc.deleteSelection()
          doc.insertText(t)
          app.tabs.docs[app.tabs.active] = doc
      of "a":
        doc.selectAll()
        app.tabs.docs[app.tabs.active] = doc
      of "z":
        doc.undo()
        app.tabs.docs[app.tabs.active] = doc
      of "y":
        doc.redo()
        app.tabs.docs[app.tabs.active] = doc
      of "s":
        let (ok, err) = saveFile(doc)
        app.tabs.docs[app.tabs.active] = doc
        app.setStatus(if ok: "saved" else: err)
      of "w":
        discard app.tabs.closeActive()
      of "q":
        app.quit = true
      else:
        discard
    elif kmAlt in key.mods:
      discard
    else:
      if doc.selection.active:
        doc.deleteSelection()
      doc.insertText(key.rune.toUTF8)
      app.tabs.docs[app.tabs.active] = doc
      app.refreshOutlines()
  else:
    discard

proc applyMenuAction(app: var App, action: MenuAction) =
  var doc = app.tabs.current
  case action
  of maCopy:
    let t = if doc.selection.active: doc.selectedText() else: ""
    if t.len > 0: discard copyToClipboard(t)
  of maCut:
    let t = if doc.selection.active: doc.selectedText() else: ""
    if t.len > 0:
      discard copyToClipboard(t)
      doc.deleteSelection()
  of maPaste:
    let t = pasteFromClipboard()
    if t.len > 0:
      if doc.selection.active: doc.deleteSelection()
      doc.insertText(t)
  of maDelete:
    doc.deleteSelection()
  of maSelectAll:
    doc.selectAll()
  of maNone:
    discard
  app.tabs.docs[app.tabs.active] = doc
  app.menu.close()

proc handleMouse(app: var App, m: MouseEvent) =
  if app.menu.visible and m.kind == mkDown:
    let hit = app.menu.hitTest(m.col, m.row)
    if hit.isSome:
      app.applyMenuAction(hit.get)
      return
    else:
      app.menu.close()

  if m.kind == mkDown and m.button == mbRight:
    app.menu.openAt(m.col, m.row)
    return

  # Tab bar clicks
  if app.panelRects.top.contains(m.col, m.row) and m.kind == mkDown and m.button == mbLeft:
    let titles = app.tabs.titles()
    var x = app.panelRects.top.left
    for i, t in titles:
      let w = t.len + 3
      if m.col >= x and m.col < x + w:
        app.tabs.selectTab(i)
        app.refreshOutlines()
        return
      x += w

  # File tree
  let tree = app.fileTreeArea()
  if tree.contains(m.col, m.row) and m.kind == mkDown and m.button == mbLeft:
    let innerY = m.row - tree.top - 1
    let idx = app.fileState.offset + innerY
    if idx == 0:
      app.cwd = parentDir(app.cwd)
      app.refreshFileTree()
      return
    let fileIdx = idx - 1
    if fileIdx >= 0 and fileIdx < app.fileEntries.len:
      app.fileState.select(idx)
      let e = app.fileEntries[fileIdx]
      if e.isDir:
        app.cwd = e.path
        app.refreshFileTree()
      else:
        app.openPath(e.path)
    return

  # Outlines
  let oa = app.outlinesArea()
  if not oa.isEmpty and oa.contains(m.col, m.row) and m.kind == mkDown:
    let innerY = m.row - oa.top - 1
    let idx = app.outlineState.offset + innerY
    if idx >= 0 and idx < app.outlineItems.len:
      app.outlineState.select(idx)
      var doc = app.tabs.current
      doc.setCursor(Cursor(row: app.outlineItems[idx].line, col: 0))
      app.tabs.docs[app.tabs.active] = doc
      app.scrollY = max(0, app.outlineItems[idx].line - 2)
      app.focus = fpEditor
    return

  # Editor mouse
  let ed = app.panelRects.center
  if ed.contains(m.col, m.row):
    let inner = rect(ed.left + 1, ed.top + 1, max(0, ed.width.int - 2), max(0, ed.height.int - 2))
    if inner.contains(m.col, m.row):
      let row = app.scrollY + (m.row - inner.top)
      let col = app.scrollX + (m.col - inner.left)
      var doc = app.tabs.current
      if m.kind == mkDown and m.button == mbLeft:
        doc.setCursor(Cursor(row: row, col: col))
        doc.beginSelection()
        app.mouseSelecting = true
        app.tabs.docs[app.tabs.active] = doc
        app.focus = fpEditor
      elif (m.kind == mkDown or m.kind == mkDrag) and app.mouseSelecting:
        doc.cursor = doc.clampCursor(Cursor(row: row, col: col))
        doc.updateSelectionHead()
        app.tabs.docs[app.tabs.active] = doc
      elif m.kind == mkUp:
        app.mouseSelecting = false
      elif m.kind == mkScrollUp:
        app.scrollY = max(0, app.scrollY - 3)
      elif m.kind == mkScrollDown:
        app.scrollY += 3

proc handleEvent*(app: var App, ev: Event) =
  case ev.kind
  of evKey:
    let key = ev.key
    if key.code == kcChar and kmCtrl in key.mods and key.rune.toUTF8.toLowerAscii == "q":
      app.quit = true
      return
    if app.menu.visible:
      case key.code
      of kcEsc:
        app.menu.close()
      of kcUp:
        app.menu.selected = max(0, app.menu.selected - 1)
      of kcDown:
        app.menu.selected = min(app.menu.items.high, app.menu.selected + 1)
      of kcEnter:
        app.applyMenuAction(app.menu.actionAt(app.menu.selected))
      else:
        discard
      return
    if app.commandMode:
      case key.code
      of kcEsc:
        app.commandMode = false
        app.commandLine = ""
      of kcEnter:
        let line = app.commandLine
        app.commandMode = false
        app.commandLine = ""
        app.runCommand(line)
      of kcBackspace:
        if app.commandLine.len > 0:
          app.commandLine.setLen(app.commandLine.len - 1)
      of kcChar:
        if kmCtrl notin key.mods:
          app.commandLine.add key.rune.toUTF8
      else:
        discard
      return
    if app.focus == fpAi and not app.commandMode:
      case key.code
      of kcEsc:
        app.focus = fpEditor
      of kcEnter:
        let prompt = app.ai.input
        app.ai.input = ""
        if prompt.len > 0:
          let bufCtx = app.tabs.current.text()
          let clipped = if bufCtx.len > 4000: bufCtx[0 ..< 4000] else: bufCtx
          discard app.ai.ask(prompt, clipped)
      of kcBackspace:
        if app.ai.input.len > 0:
          app.ai.input.setLen(app.ai.input.len - 1)
      of kcChar:
        if kmCtrl notin key.mods:
          app.ai.input.add key.rune.toUTF8
      else:
        discard
      return
    # Start command mode
    if key.code == kcChar and key.rune.toUTF8 == ":" and kmCtrl notin key.mods and
        app.focus == fpEditor:
      # Helix/Vim: colon starts command — in insert-friendly mode only when alone at idle;
      # for Tai we use ':' always to enter command mode (Helix-like).
      app.commandMode = true
      app.commandLine = ""
      return
    if key.code == kcTab and kmCtrl notin key.mods:
      case app.focus
      of fpEditor: app.focus = fpFileTree
      of fpFileTree: app.focus = fpOutlines
      of fpOutlines: app.focus = fpAi
      of fpAi, fpCommand: app.focus = fpEditor
      return
    if app.focus == fpEditor:
      app.handleEditorKey(key)
  of evMouse:
    app.handleMouse(ev.mouse)
  of evPaste:
    var doc = app.tabs.current
    doc.insertText(ev.text)
    app.tabs.docs[app.tabs.active] = doc
  of evResize:
    discard
  else:
    discard

proc enableMouse*() =
  stdout.write "\e[?1000h\e[?1002h\e[?1003h\e[?1006h"
  stdout.flushFile()

proc disableMouse*() =
  stdout.write "\e[?1000l\e[?1002l\e[?1003l\e[?1006l"
  stdout.flushFile()

proc runApp*(app: var App) =
  var state: ref App
  new(state)
  state[] = app
  var term = newTerminal(newAnsiBackend())
  term.setup()
  enableMouse()
  defer:
    disableMouse()
    term.restore()
    app = state[]
  while not state.quit:
    for path in state.watcher.poll():
      if state.tabs.current.path == path and not state.tabs.current.dirty:
        let loaded = loadFile(path)
        if loaded.ok:
          state.tabs.docs[state.tabs.active] = loaded.doc
          state[].refreshOutlines()
          state[].setStatus("reloaded " & path.extractFilename)
    term.draw(proc(f: var Frame) = state[].draw(f))
    let ev = pollEvent(50)
    if ev.isSome:
      state[].handleEvent(ev.get)
