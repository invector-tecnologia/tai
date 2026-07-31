## Application state, layout, draw loop, and input handling.

import std/[os, strutils, options, times, unicode]
import tatui
import tatui/core/[rect, style, unicodewidth]

import ./config
import ./buffer/[document, tabs, wrap]
import ./fs/[io, clipboard, watcher]
import ./commands/dispatch
import ./editor/context_menu
import ./highlight/engine
import ./highlight/treesitter
import ./outline/extract
import ./preview/render
import ./ai/[provider, rag, rtk, skills, mcp]
import ./git/cmd
import std/tables
import ./theme
import ./ui/brand
import ./ui/utf8clip
import ./audio/player
import ./version

type
  FocusPanel* = enum
    fpEditor
    fpFileTree
    fpOutlines
    fpCommand
    fpAi

  EditorMode* = enum
    emInsert
    emNormal

  PanelRects* = object
    header*, tabs*, left*, center*, right*, bottom*: Rect

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
    audio*: AudioPlayer
    lastFrameMs*: float
    panelRects*: PanelRects
    editorMode*: EditorMode
    vimPending*: string ## multi-key (dd, gg, yy)
    yankBuffer*: string
    confirmClose*: bool
    confirmTab*: int
    confirmSelected*: int ## 0=Salvar, 1=Não salvar, 2=Cancelar
    confirmArea*: Rect
    preferredCol*: int ## display column for visual-line up/down

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
  elif loaded.refuse:
    app.setStatus(loaded.error)
  else:
    var doc = emptyDocument(path)
    app.tabs.openDoc(doc)
    app.setStatus(loaded.error)

proc bufferContext(app: App): string =
  let doc = app.tabs.current
  if doc.selection.active:
    let sel = doc.selectedText()
    if sel.len > 0:
      let clipped = if sel.len > 6000: sel[0 ..< 6000] else: sel
      return "Selection from " & doc.displayName() & ":\n" & clipped
  let buf = doc.text()
  let clipped = if buf.len > 4000: buf[0 ..< 4000] else: buf
  if clipped.len == 0: return ""
  "File " & doc.displayName() & ":\n" & clipped

proc initApp*(cfg: Config): App =
  result.cfg = cfg
  result.tabs = initTabManager()
  result.cwd = if dirExists(cfg.workspace): cfg.workspace else: getCurrentDir()
  result.menu = initContextMenu()
  result.watcher = initFileWatcher()
  setTheme(cfg.theme)
  result.ai = initAiSession(
    cfg.ai,
    getConfigDir() / "tai" / "cache",
    result.cwd,
    cfg.hooks,
    cfg.mcpServers,
  )
  result.audio = initAudioPlayer(cfg.audio.url)
  result.focus = fpEditor
  result.editorMode = if cfg.keymap == kmVim: emNormal else: emInsert
  result.refreshFileTree()
  result.refreshOutlines()
  result.setStatus("Tai v" & TaiVersion & " — :help")
  if cfg.audio.autoplay and cfg.audio.url.len > 0:
    result.audio.play()

proc headerHeight(width: int): int =
  ## Banner rows + credit line.
  let lines = bannerLines(width)
  lines.len + 1

proc computeLayout*(app: var App, area: Rect): PanelRects =
  let hdrH = headerHeight(area.width.int)
  let topH = hdrH + 1 # header + tabs
  let bottomH = max(3, app.cfg.bottomPanelHeight)
  let sideW = max(12, app.cfg.sidePanelWidth)
  let showFiles = app.cfg.filesVisible
  let showOutlines = app.cfg.outlinesVisible
  let rows = area.split(Vertical, @[length(topH), fill(1), length(bottomH)])
  let topSplit = rows[0].split(Vertical, @[length(hdrH), length(1)])
  result.header = topSplit[0]
  result.tabs = topSplit[1]
  result.bottom = rows[2]
  let mid = rows[1]

  if showFiles and showOutlines:
    let cols = mid.split(Horizontal, @[length(sideW), fill(1), length(sideW)])
    result.left = cols[0]
    result.center = cols[1]
    result.right = cols[2]
  elif showFiles:
    if app.cfg.fileTreeSide == ftsLeft:
      let cols = mid.split(Horizontal, @[length(sideW), fill(1)])
      result.left = cols[0]
      result.center = cols[1]
      result.right = rect(0, 0, 0, 0)
    else:
      let cols = mid.split(Horizontal, @[fill(1), length(sideW)])
      result.left = rect(0, 0, 0, 0)
      result.center = cols[0]
      result.right = cols[1]
  elif showOutlines:
    # Outlines occupy the side opposite to the preferred file-tree side.
    if app.cfg.fileTreeSide == ftsLeft:
      let cols = mid.split(Horizontal, @[fill(1), length(sideW)])
      result.left = rect(0, 0, 0, 0)
      result.center = cols[0]
      result.right = cols[1]
    else:
      let cols = mid.split(Horizontal, @[length(sideW), fill(1)])
      result.left = cols[0]
      result.center = cols[1]
      result.right = rect(0, 0, 0, 0)
  else:
    result.left = rect(0, 0, 0, 0)
    result.center = mid
    result.right = rect(0, 0, 0, 0)
  app.panelRects = result

proc fileTreeArea(app: App): Rect =
  if not app.cfg.filesVisible:
    return rect(0, 0, 0, 0)
  if app.cfg.fileTreeSide == ftsLeft: app.panelRects.left
  else: app.panelRects.right

proc outlinesArea(app: App): Rect =
  if not app.cfg.outlinesVisible:
    return rect(0, 0, 0, 0)
  if app.cfg.fileTreeSide == ftsLeft: app.panelRects.right
  else: app.panelRects.left

proc focusRing*(app: App): seq[FocusPanel] =
  ## Visible panels in Tab order: Editor → Files → Outlines → AI.
  result = @[fpEditor]
  if app.cfg.filesVisible:
    result.add fpFileTree
  if app.cfg.outlinesVisible:
    result.add fpOutlines
  result.add fpAi

proc ensureFocusVisible*(app: var App) =
  ## Snap focus back to the editor if it points at a hidden panel.
  let ring = app.focusRing()
  if app.focus notin ring:
    app.focus = fpEditor

proc cycleFocus*(app: var App, dir: int) =
  ## Move focus along `focusRing` by `dir` (+1 forward / -1 back).
  app.ensureFocusVisible()
  let ring = app.focusRing()
  if ring.len == 0:
    return
  var idx = 0
  for i, p in ring:
    if p == app.focus:
      idx = i
      break
  let n = ring.len
  idx = ((idx + dir) mod n + n) mod n
  app.focus = ring[idx]

proc tabIndexAt(app: App, col, row: int): int =
  if not app.panelRects.tabs.contains(col, row):
    return -1
  let titles = app.tabs.titles()
  var x = app.panelRects.tabs.left
  for i, t in titles:
    let w = t.len + 3
    if col >= x and col < x + w:
      return i
    x += w
  -1

proc docDisplayBase(d: Document): string =
  if d.path.len == 0: "[scratch]"
  else: d.path.extractFilename

proc resolveSavePath(app: App, doc: var Document) =
  ## Absolute path kept; empty/relative resolved under the file-tree cwd.
  if doc.path.len == 0:
    doc.path = app.cwd / "scratch"
  elif not isAbsolute(doc.path):
    doc.path = app.cwd / doc.path.extractFilename

proc performCloseTab(app: var App, index: int) =
  discard app.tabs.closeTab(index)
  app.scrollY = 0
  app.refreshOutlines()

proc overlayOpen(app: App): bool =
  app.menu.visible or app.confirmClose

proc requestCloseTab*(app: var App, index: int) =
  if index < 0 or index >= app.tabs.docs.len:
    return
  if not app.tabs.docs[index].dirty:
    app.performCloseTab(index)
    return
  app.menu.close()
  app.confirmClose = true
  app.confirmTab = index
  app.confirmSelected = 0

proc cancelConfirmClose(app: var App) =
  app.confirmClose = false
  app.confirmTab = -1
  app.confirmSelected = 0

proc applyConfirmClose(app: var App) =
  if not app.confirmClose:
    return
  let idx = app.confirmTab
  case app.confirmSelected
  of 0: # Salvar
    if idx < 0 or idx >= app.tabs.docs.len:
      app.cancelConfirmClose()
      return
    var doc = app.tabs.docs[idx]
    app.resolveSavePath(doc)
    let (ok, err) = saveFile(doc)
    app.tabs.docs[idx] = doc
    if ok:
      app.watcher.watch(doc.path)
      app.cancelConfirmClose()
      app.performCloseTab(idx)
      app.setStatus("saved")
      app.refreshFileTree()
    else:
      app.setStatus(err)
  of 1: # Não salvar
    app.cancelConfirmClose()
    app.performCloseTab(idx)
  else: # Cancelar
    app.cancelConfirmClose()

proc drawConfirmClose(app: var App, f: var Frame) =
  if not app.confirmClose:
    return
  let name =
    if app.confirmTab >= 0 and app.confirmTab < app.tabs.docs.len:
      docDisplayBase(app.tabs.docs[app.confirmTab])
    else: "?"
  let msg = "Salvar alterações em " & name & "?"
  const options = ["Salvar", "Não salvar", "Cancelar"]
  var maxW = displayWidth(msg)
  for o in options:
    maxW = max(maxW, displayWidth(o))
  # Include border rows/cols so all three options stay visible.
  let w = maxW + 6
  let h = 2 + 1 + options.len
  var x = max(0, (f.area.width.int - w) div 2)
  var y = max(0, (f.area.height.int - h) div 2)
  if x + w > f.area.right: x = max(0, f.area.right - w)
  if y + h > f.area.bottom: y = max(0, f.area.bottom - h)
  let area = rect(x, y, w, h)
  app.confirmArea = area
  let blk = initBlock(borders = AllBorders, title = " Fechar ", borderType = btRounded)
  f.renderWidget(blk, area)
  let inner = blk.inner(area)
  if inner.isEmpty:
    return
  discard f.buf[].setStringN(inner.left, inner.top, " " & msg, tnFg(Tn.fg), inner.width.int)
  for i, opt in options:
    let st =
      if i == app.confirmSelected:
        tnHl(Tn.black, Tn.cyan, {mBold})
      else:
        tnFg(Tn.fg)
    let row = inner.top + 1 + i
    if row < inner.bottom:
      discard f.buf[].setStringN(inner.left, row, " " & opt, st, inner.width.int)

proc drawContextMenu(app: var App, f: var Frame) =
  if not app.menu.visible:
    return
  var maxLabel = 0
  for item in app.menu.items:
    maxLabel = max(maxLabel, displayWidth(item.label))
  let w = max(18, maxLabel + 6)
  let h = 2 + app.menu.items.len
  # Center like the close overlay (ignore click coordinates).
  var x = max(0, (f.area.width.int - w) div 2)
  var y = max(0, (f.area.height.int - h) div 2)
  if x + w > f.area.right: x = max(0, f.area.right - w)
  if y + h > f.area.bottom: y = max(0, f.area.bottom - h)
  let area = rect(x, y, w, h)
  app.menu.area = area
  let title = if app.menu.isTabMenu: " Tab " else: " Edit "
  let blk = initBlock(borders = AllBorders, title = title, borderType = btRounded)
  f.renderWidget(blk, area)
  let inner = blk.inner(area)
  for i, item in app.menu.items:
    let st =
      if i == app.menu.selected:
        tnHl(Tn.black, Tn.cyan, {mBold})
      else:
        tnFg(Tn.fg)
    if inner.top + i < inner.bottom:
      discard f.buf[].setStringN(inner.left, inner.top + i, " " & item.label, st, inner.width.int)

proc spanKindAt(hl: HighlightedLine, byteIdx: int): TokenKind =
  for sp in hl.spans:
    if byteIdx >= sp.start and byteIdx < sp.finish:
      return sp.kind
  tkPlain

proc editorViewWidth(app: App): int =
  max(1, app.panelRects.center.width.int - 2)

proc editorViewHeight(app: App): int =
  max(1, app.panelRects.center.height.int - 2)

proc buildEditorVisual(app: App): seq[VisualRow] =
  buildVisualRows(app.tabs.current.lines, app.editorViewWidth())

proc updatePreferredCol(app: var App) =
  let doc = app.tabs.current
  if doc.cursor.row < 0 or doc.cursor.row > doc.lines.high:
    app.preferredCol = 0
    return
  app.preferredCol = displayColAtByte(doc.lines[doc.cursor.row], doc.cursor.col)

proc drawEditor(app: var App, f: var Frame, area: Rect) =
  var doc = app.tabs.current
  let focused = app.focus == fpEditor
  let title =
    if doc.previewMode: " Preview "
    else: " " & doc.displayName() & " "
  var blk = initBlock(title = title, borders = AllBorders)
  if focused:
    blk.borderStyle = tnFg(Tn.cyan, {mBold})
    blk.titleStyle = tnFg(Tn.cyan, {mBold})
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
  let visual = buildVisualRows(lines, viewW)
  if app.scrollY > max(0, visual.len - viewH):
    app.scrollY = max(0, visual.len - viewH)

  let endVis = min(visual.high, app.scrollY + viewH - 1)
  var hlCache = initTable[int, HighlightedLine]()
  if not doc.previewMode and visual.len > 0 and app.scrollY <= endVis:
    var minSrc = visual[app.scrollY].srcLine
    var maxSrc = visual[endVis].srcLine
    let highlighted = highlightRangeAuto(app.cfg.highlightEngine, lang, lines, minSrc, maxSrc)
    for i, hl in highlighted:
      hlCache[minSrc + i] = hl

  let rowStyle = tnHl(Tn.fg, Tn.bg)
  for row in 0 ..< viewH:
    let visIdx = app.scrollY + row
    let y = inner.top + row
    discard f.buf[].setStringN(inner.left, y, repeat(' ', viewW), rowStyle, viewW)
    if visIdx > visual.high:
      continue
    let vr = visual[visIdx]
    if vr.srcLine > lines.high:
      continue
    let line = lines[vr.srcLine]
    let useHl = not doc.previewMode and hlCache.hasKey(vr.srcLine)
    let paintStart =
      if vr.hard: floorRuneIndex(line, app.scrollX)
      else: vr.startByte
    let paintEnd = vr.endByte
    var x = inner.left
    var i = max(paintStart, vr.startByte)
    if vr.hard and paintStart > vr.startByte:
      i = paintStart
    while i < paintEnd and i < line.len and x < inner.right:
      let n = safeRuneLen(line, i)
      let chunk = line[i ..< i + n]
      let w = displayWidth(chunk)
      if w <= 0:
        i += n
        continue
      if x + w > inner.right:
        break
      let st =
        if useHl: tokenStyle(spanKindAt(hlCache[vr.srcLine], i))
        else: rowStyle
      discard f.buf[].setStringN(x, y, chunk, rowStyle.patch(st), inner.right - x)
      x += w
      i += n
    if doc.selection.active and not doc.previewMode:
      let (a, b) = doc.normalizedSelection()
      if vr.srcLine >= a.row and vr.srcLine <= b.row:
        discard f.buf[].setStringN(inner.left, y, "▌", tnFg(Tn.cyan), 1)

  if app.focus == fpEditor and not doc.previewMode and not app.commandMode:
    let vi = visualIndexAt(visual, doc.cursor.row, doc.cursor.col)
    let cy = vi - app.scrollY
    if cy >= 0 and cy < viewH and vi <= visual.high:
      let vr = visual[vi]
      let line = lines[vr.srcLine]
      let absCol = displayColAtByte(line, floorRuneIndex(line, doc.cursor.col))
      let origin =
        if vr.hard: displayColAtByte(line, floorRuneIndex(line, app.scrollX))
        else: displayColAtByte(line, vr.startByte)
      let cx = absCol - origin
      if cx >= 0 and cx < viewW:
        f.setCursor(pos(inner.left + cx, inner.top + cy))

proc drawSideList(
    f: var Frame, area: Rect, title: string, labels: seq[string], state: var ListState,
    focused = false,
) =
  var items: seq[ListItem]
  for lab in labels:
    items.add listItem(lab)
  var blk = initBlock(title = title, borders = AllBorders)
  if focused:
    blk.borderStyle = tnFg(Tn.cyan, {mBold})
    blk.titleStyle = tnFg(Tn.cyan, {mBold})
  let lst = list(
    items,
    blk = some(blk),
    highlightStyle = tnHl(Tn.black, Tn.blue),
    highlightSymbol = "› ",
  )
  f.renderStateful(lst, area, state)

proc drawHeader(app: var App, f: var Frame, area: Rect) =
  if area.isEmpty: return
  # Fill background
  for row in 0 ..< area.height.int:
    discard f.buf[].setStringN(
      area.left, area.top + row, repeat(' ', area.width.int),
      tnHl(Tn.fg, Tn.bg), area.width.int
    )
  let banner = bannerLines(area.width.int)
  let brandStyle = tnFg(Tn.blue, {mBold})
  for i, line in banner:
    if i >= area.height.int - 1: break
    let clipped = clipToDisplayWidth(line, area.width.int)
    discard f.buf[].setStringN(
      area.left, area.top + i, clipped, brandStyle, area.width.int
    )
  # Credit + version on last banner-adjacent line
  let creditRow = max(0, min(banner.len, area.height.int - 1))
  if creditRow >= 0 and creditRow < area.height.int:
    let credit = creditWithVersion(max(10, area.width.int - 28))
    discard f.buf[].setStringN(
      area.left, area.top + creditRow, credit, tnFg(Tn.comment), area.width.int
    )
  # Player controls on the right of the credit row
  let playLbl = if app.audio.state == asPlaying: "[❚❚]" else: "[▶]"
  let nextLbl = "[⏭]"
  let status = app.audio.statusLabel()
  var right = playLbl & " " & nextLbl & " " & status
  if right.len > area.width.int div 2:
    right = playLbl & " " & nextLbl
  let rx = area.right - right.len
  if creditRow >= 0 and creditRow < area.height.int and rx > area.left:
    let playStyle =
      if app.audio.state == asPlaying: tnFg(Tn.green, {mBold})
      else: tnFg(Tn.cyan, {mBold})
    discard f.buf[].setStringN(rx, area.top + creditRow, right, playStyle, right.len)
    app.audio.playBtn = (rx, area.top + creditRow, playLbl.len)
    app.audio.nextBtn = (rx + playLbl.len + 1, area.top + creditRow, nextLbl.len)
  else:
    app.audio.playBtn = (0, 0, 0)
    app.audio.nextBtn = (0, 0, 0)

proc draw*(app: var App, f: var Frame) =
  let t0 = cpuTime()
  let layout = app.computeLayout(f.area)

  app.drawHeader(f, layout.header)

  # Tabs
  let titles = app.tabs.titles()
  let tabBar = tabs(
    titles,
    selected = app.tabs.active,
    highlightStyle = tnHl(Tn.black, Tn.blue, {mBold}),
    divider = " │ ",
  )
  f.renderWidget(tabBar, layout.tabs)

  # File tree
  let treeArea = app.fileTreeArea()
  if not treeArea.isEmpty:
    var labels: seq[string]
    labels.add ".. (parent)"
    for e in app.fileEntries:
      labels.add e.name
    var st = app.fileState
    drawSideList(f, treeArea, " Files ", labels, st, focused = app.focus == fpFileTree)
    app.fileState = st

  # Outlines
  let outArea = app.outlinesArea()
  if not outArea.isEmpty:
    var labels: seq[string]
    for o in app.outlineItems:
      labels.add repeat("  ", o.depth) & o.label
    var st = app.outlineState
    drawSideList(f, outArea, " Outlines ", labels, st, focused = app.focus == fpOutlines)
    app.outlineState = st

  # Center editor
  app.drawEditor(f, layout.center)

  # Bottom: AI + command
  let agentTag = modeName(app.ai.mode)
  let busyTag = if app.ai.busy: " …" else: ""
  let modeHint =
    if app.cfg.keymap == kmVim:
      (if app.editorMode == emNormal: " NORMAL" else: " INSERT")
    else: ""
  var bottomBlk = initBlock(
    title = " AI/" & agentTag & busyTag & modeHint & "  [" & formatGain(app.ai.stats) &
      " | " & $app.lastFrameMs.int & "ms] ",
    borders = AllBorders,
  )
  if app.focus == fpAi:
    bottomBlk.borderStyle = tnFg(Tn.cyan, {mBold})
    bottomBlk.titleStyle = tnFg(Tn.cyan, {mBold})
  f.renderWidget(bottomBlk, layout.bottom)
  let bInner = bottomBlk.inner(layout.bottom)
  if not bInner.isEmpty:
    let promptRow = 1
    let msgRows = max(1, bInner.height.int - promptRow)
    let lines = visibleTranscript(app.ai, msgRows)
    for i, line in lines:
      let clipped = clipToDisplayWidth(line, bInner.width.int)
      discard f.buf[].setStringN(
        bInner.left, bInner.top + i, clipped, tnFg(Tn.fg), bInner.width.int
      )
    let prompt =
      if app.commandMode: ":" & app.commandLine & "█"
      elif app.focus == fpAi: "ai> " & app.ai.input & "█"
      else:
        let st =
          if epochTime() < app.statusUntil: app.statusMsg
          else: "Shift-Tab panels │ Esc editor │ Ctrl-W close │ :help"
        st
    if bInner.height.int > 0:
      let py = bInner.top + bInner.height.int - 1
      discard f.buf[].setStringN(
        bInner.left, py, clipToDisplayWidth(prompt, bInner.width.int),
        tnFg(Tn.cyan), bInner.width.int
      )

  app.drawContextMenu(f)
  app.drawConfirmClose(f)
  app.lastFrameMs = (cpuTime() - t0) * 1000

proc ensureCursorVisible(app: var App, areaH: int) =
  let visual = app.buildEditorVisual()
  if visual.len == 0:
    app.scrollY = 0
    return
  let doc = app.tabs.current
  let vi = visualIndexAt(visual, doc.cursor.row, doc.cursor.col)
  if vi < app.scrollY:
    app.scrollY = vi
  elif vi >= app.scrollY + areaH:
    app.scrollY = vi - areaH + 1

proc moveVisualLine(app: var App, delta: int, selecting: bool) =
  var doc = app.tabs.current
  if selecting and not doc.selection.active:
    doc.beginSelection()
  elif not selecting:
    doc.clearSelection()
  let visual = app.buildEditorVisual()
  if visual.len == 0:
    return
  var vi = visualIndexAt(visual, doc.cursor.row, doc.cursor.col)
  vi = clamp(vi + delta, 0, visual.high)
  let vr = visual[vi]
  let line = doc.lines[vr.srcLine]
  let startDisp = displayColAtByte(line, vr.startByte)
  let endDisp = displayColAtByte(line, vr.endByte)
  let want =
    if endDisp > startDisp: clamp(app.preferredCol, startDisp, endDisp - 1)
    else: startDisp
  doc.cursor = doc.clampCursor(Cursor(row: vr.srcLine, col: byteAtDisplayCol(line, want)))
  if selecting:
    doc.updateSelectionHead()
  app.tabs.docs[app.tabs.active] = doc
  app.ensureCursorVisible(app.editorViewHeight())

proc moveCursor(app: var App, drow, dcol: int, selecting: bool) =
  if drow != 0 and dcol == 0:
    app.moveVisualLine(drow, selecting)
    return
  var doc = app.tabs.current
  if selecting and not doc.selection.active:
    doc.beginSelection()
  elif not selecting:
    doc.clearSelection()
  doc.cursor = doc.clampCursor(Cursor(row: doc.cursor.row + drow, col: doc.cursor.col + dcol))
  if selecting:
    doc.updateSelectionHead()
  app.tabs.docs[app.tabs.active] = doc
  app.updatePreferredCol()
  app.ensureCursorVisible(app.editorViewHeight())

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
      app.setStatus(app.ai.messages[^1])
  of "provider":
    if parts.len >= 2:
      app.ai.setProvider(parts[1])
      app.cfg.ai = app.ai.cfg
      saveConfig(app.cfg)
    else:
      app.setStatus("usage: :provider openai|anthropic|ollama")
  of "model":
    let m = if parts.len >= 2: parts[1 .. ^1].join(" ") else: ""
    app.ai.setModel(m)
    if m.len > 0:
      app.cfg.ai = app.ai.cfg
      saveConfig(app.cfg)
  of "ask":
    app.ai.setMode(amAsk)
    app.cfg.ai.mode = amAsk
    saveConfig(app.cfg)
    if parts.len > 1:
      app.ai.startAskAsync(parts[1 .. ^1].join(" "), app.bufferContext())
    else:
      app.setStatus("mode: ask")
  of "plan":
    app.ai.setMode(amPlan)
    app.cfg.ai.mode = amPlan
    saveConfig(app.cfg)
    if parts.len > 1:
      app.ai.startAskAsync(parts[1 .. ^1].join(" "), app.bufferContext())
    else:
      app.setStatus("mode: plan (read-only tools)")
  of "agent":
    if parts.len >= 2 and parts[1].toLowerAscii in ["off", "0", "false"]:
      app.ai.setMode(amAsk)
      app.cfg.ai.mode = amAsk
      saveConfig(app.cfg)
      app.setStatus("mode: ask")
    else:
      app.ai.setMode(amAgent)
      app.cfg.ai.mode = amAgent
      saveConfig(app.cfg)
      if parts.len > 1 and parts[1].toLowerAscii notin ["on", "1", "true"]:
        app.ai.startAskAsync(parts[1 .. ^1].join(" "), app.bufferContext())
      else:
        app.setStatus("mode: agent (write/shell enabled)")
  of "mode":
    if parts.len < 2:
      app.setStatus("usage: :mode ask|plan|agent  (now: " & modeName(app.ai.mode) & ")")
    else:
      let m = parseMode(parts[1])
      app.ai.setMode(m)
      app.cfg.ai.mode = m
      saveConfig(app.cfg)
      app.setStatus("mode: " & modeName(m))
  of "clear":
    app.ai.clearChat()
    app.setStatus("chat cleared")
  of "rag":
    if parts.len >= 2 and parts[1] == "reindex":
      app.ai.rag = reindex(app.cwd)
      app.setStatus("RAG indexed " & $app.ai.rag.chunks.len & " chunks")
    else:
      app.setStatus("usage: :rag reindex")
  of "shell":
    if parts.len < 2:
      app.setStatus("usage: :shell <command>")
      return
    if app.ai.mode != amAgent:
      app.setStatus("shell blocked — :agent first")
      return
    let cmdLine = parts[1 .. ^1].join(" ")
    let r = runWithRtk(cmdLine)
    app.ai.stats.rtkSavedTokens += r.savedTokens
    app.ai.pushMsg "shell" & (if r.usedRtk: " (rtk)" else: "") & ": " & cmdLine
    for line in r.output.splitLines():
      app.ai.pushMsg "  " & line
  of "git":
    if parts.len < 2:
      app.setStatus("usage: :git status|diff|log|branch|add|commit")
      return
    let sub = parts[1].toLowerAscii
    var gr: GitResult
    case sub
    of "status": gr = gitStatus(app.cwd)
    of "diff": gr = gitDiff(app.cwd)
    of "log": gr = gitLog(app.cwd)
    of "branch": gr = gitBranch(app.cwd)
    of "add":
      let paths = if parts.len > 2: parts[2 .. ^1] else: @[]
      gr = gitAdd(app.cwd, paths)
    of "commit":
      if parts.len < 3:
        app.setStatus("usage: :git commit <message>")
        return
      gr = gitCommit(app.cwd, parts[2 .. ^1].join(" "))
    else:
      app.setStatus("unknown :git subcommand")
      return
    app.ai.pushMsg "git " & sub & ":"
    for line in gr.output.splitLines():
      app.ai.pushMsg "  " & line
    app.setStatus(if gr.ok: "git " & sub & " ok" else: "git " & sub & " failed")
  of "mcp":
    if parts.len < 2:
      app.setStatus("usage: :mcp list|reload")
      return
    case parts[1].toLowerAscii
    of "list":
      app.ai.mcp.ensureStarted()
      app.ai.pushMsg app.ai.mcp.listSummary()
      app.setStatus("mcp list")
    of "reload":
      app.ai.mcp.servers = app.cfg.mcpServers
      app.ai.mcp.reload()
      app.ai.pushMsg app.ai.mcp.listSummary()
      app.setStatus("mcp reloaded")
    else:
      app.setStatus("usage: :mcp list|reload")
  of "skills", "skill":
    app.ai.skills = discoverSkills(app.cwd)
    app.ai.rebuildSystem()
    if app.ai.skills.len == 0:
      app.setStatus("no skills found")
    else:
      var names: seq[string]
      for n, _ in app.ai.skills: names.add n
      app.setStatus("skills: " & names.join(", "))
  of "ai":
    let prompt = if parts.len > 1: parts[1 .. ^1].join(" ") else: ""
    if prompt.len == 0:
      app.focus = fpAi
      app.setStatus("AI focus — type message, Enter to send")
    else:
      app.ai.startAskAsync(prompt, app.bufferContext())
  of "audio":
    if parts.len < 2:
      app.setStatus("usage: :audio play|pause|next|stop|url <link>")
      return
    case parts[1].toLowerAscii
    of "play":
      app.audio.play()
      app.setStatus(app.audio.statusLabel())
    of "pause":
      app.audio.pause()
      app.setStatus(app.audio.statusLabel())
    of "next":
      app.audio.nextTrack()
      app.setStatus(app.audio.statusLabel())
    of "stop":
      app.audio.stop()
      app.setStatus("audio stopped")
    of "url":
      if parts.len < 3:
        app.setStatus("usage: :audio url <youtube-link>")
        return
      let link = parts[2 .. ^1].join(" ")
      app.audio.setUrl(link)
      app.cfg.audio.url = link
      saveConfig(app.cfg)
      app.setStatus("audio url set")
    of "toggle":
      app.audio.toggle()
      app.setStatus(app.audio.statusLabel())
    else:
      app.setStatus("usage: :audio play|pause|next|stop|url <link>")
  else:
    discard

proc runCommand(app: var App, line: string) =
  var doc = app.tabs.docs[app.tabs.active]
  var ctx = CommandContext(cfg: addr app.cfg, doc: addr doc, status: "")
  let r = dispatchCommand(ctx, line)
  app.tabs.docs[app.tabs.active] = doc
  if r.aiCmd.len > 0:
    app.handleAiCommand(r.aiCmd)
  elif r.openPath.len > 0:
    app.openPath(r.openPath)
  elif r.newCwd.len > 0:
    app.cwd = r.newCwd
    app.ai.workspace = r.newCwd
    app.ai.refreshProjectMemory(r.newCwd)
    app.refreshFileTree()
    app.setStatus(r.message)
    saveConfig(app.cfg)
  elif r.ok:
    if r.message.startsWith("theme:"):
      setTheme(app.cfg.theme)
    if r.message.startsWith("keymap:"):
      app.editorMode = if app.cfg.keymap == kmVim: emNormal else: emInsert
    if r.message.len > 0:
      app.setStatus(r.message)
    if r.quit:
      app.quit = true
    app.ensureFocusVisible()
    app.refreshOutlines()
    saveConfig(app.cfg)
  else:
    app.setStatus(r.message)

proc handleVimNormal(app: var App, key: KeyEvent): bool =
  ## Returns true if the key was handled in normal mode.
  var doc = app.tabs.current
  if key.code == kcChar and kmCtrl notin key.mods:
    let ch = key.rune.toUTF8
    let pending = app.vimPending & ch
    app.vimPending = ""
    case pending
    of "h":
      app.moveCursor(0, -1, false); return true
    of "l":
      app.moveCursor(0, 1, false); return true
    of "j":
      app.moveCursor(1, 0, false); return true
    of "k":
      app.moveCursor(-1, 0, false); return true
    of "0":
      doc.cursor.col = 0
      app.tabs.docs[app.tabs.active] = doc
      return true
    of "$":
      doc.cursor.col = doc.lines[doc.cursor.row].len
      app.tabs.docs[app.tabs.active] = doc
      return true
    of "i":
      app.editorMode = emInsert
      app.setStatus("-- INSERT --")
      return true
    of "a":
      app.moveCursor(0, 1, false)
      app.editorMode = emInsert
      app.setStatus("-- INSERT --")
      return true
    of "v":
      doc.beginSelection()
      app.tabs.docs[app.tabs.active] = doc
      return true
    of "u":
      doc.undo()
      app.tabs.docs[app.tabs.active] = doc
      return true
    of "p":
      if app.yankBuffer.len > 0:
        doc.insertText(app.yankBuffer)
        app.tabs.docs[app.tabs.active] = doc
      return true
    of "G":
      doc.setCursor(Cursor(row: doc.lines.high, col: 0))
      app.tabs.docs[app.tabs.active] = doc
      app.scrollY = max(0, doc.cursor.row - 2)
      return true
    of "gg":
      doc.setCursor(Cursor(row: 0, col: 0))
      app.tabs.docs[app.tabs.active] = doc
      app.scrollY = 0
      return true
    of "dd":
      if doc.lines.len > 0:
        app.yankBuffer = doc.lines[doc.cursor.row] & "\n"
        if doc.lines.len == 1:
          doc.lines = @[""]
        else:
          doc.lines.delete(doc.cursor.row)
          if doc.cursor.row > doc.lines.high:
            doc.cursor.row = doc.lines.high
        doc.dirty = true
        app.tabs.docs[app.tabs.active] = doc
        app.refreshOutlines()
      return true
    of "yy":
      if doc.lines.len > 0:
        app.yankBuffer = doc.lines[doc.cursor.row] & "\n"
      return true
    of "g", "d", "y":
      app.vimPending = pending
      return true
    of ":":
      app.commandMode = true
      app.commandLine = ""
      return true
    else:
      return true # swallow unknown in normal
  if key.code in {kcLeft, kcRight, kcUp, kcDown, kcHome, kcEnd, kcPageUp, kcPageDown}:
    # arrows still work
    return false
  true

proc handleEditorKey(app: var App, key: KeyEvent) =
  if app.cfg.keymap == kmVim and app.editorMode == emNormal:
    if app.handleVimNormal(key):
      return
  if app.cfg.keymap == kmVim and app.editorMode == emInsert and key.code == kcEsc:
    app.editorMode = emNormal
    app.setStatus("-- NORMAL --")
    return

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
    app.updatePreferredCol()
  of kcEnd:
    doc.cursor.col = doc.lines[doc.cursor.row].len
    if selecting: doc.updateSelectionHead() else: doc.clearSelection()
    app.tabs.docs[app.tabs.active] = doc
    app.updatePreferredCol()
  of kcPageUp:
    app.moveCursor(-(app.editorViewHeight()), 0, selecting)
  of kcPageDown:
    app.moveCursor(app.editorViewHeight(), 0, selecting)
  of kcBackspace:
    doc.backspace()
    app.tabs.docs[app.tabs.active] = doc
    app.updatePreferredCol()
    app.refreshOutlines()
  of kcDelete:
    doc.deleteForward()
    app.tabs.docs[app.tabs.active] = doc
    app.updatePreferredCol()
    app.refreshOutlines()
  of kcEnter:
    doc.newline()
    app.tabs.docs[app.tabs.active] = doc
    app.updatePreferredCol()
    app.refreshOutlines()
  of kcTab:
    doc.insertText("  ")
    app.tabs.docs[app.tabs.active] = doc
    app.updatePreferredCol()
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
      of "q":
        app.quit = true
      of "n":
        app.tabs.nextTab()
        app.refreshOutlines()
      of "p":
        app.tabs.prevTab()
        app.refreshOutlines()
      else:
        discard
    elif kmAlt in key.mods:
      discard
    else:
      if doc.selection.active:
        doc.deleteSelection()
      doc.insertText(key.rune.toUTF8)
      app.tabs.docs[app.tabs.active] = doc
      app.updatePreferredCol()
      app.refreshOutlines()
  else:
    discard

proc applyMenuAction(app: var App, action: MenuAction) =
  case action
  of maDuplicate:
    let idx = app.menu.targetTab
    app.menu.close()
    app.tabs.duplicateTab(idx)
    app.refreshOutlines()
  of maCloseTab:
    let idx = app.menu.targetTab
    app.menu.close()
    app.requestCloseTab(idx)
  of maCopy, maCut, maPaste, maDelete, maSelectAll, maNone:
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
    else:
      discard
    app.tabs.docs[app.tabs.active] = doc
    app.menu.close()

proc handleMouse(app: var App, m: MouseEvent) =
  if app.confirmClose:
    if m.kind != mkDown or m.button != mbLeft:
      return
    if app.confirmArea.contains(m.col, m.row):
      let innerTop = app.confirmArea.top + 1
      let opt = m.row - innerTop - 1 # skip message row
      if opt >= 0 and opt <= 2:
        app.confirmSelected = opt
        app.applyConfirmClose()
      return
    app.cancelConfirmClose()
    return

  if app.menu.visible:
    if m.kind != mkDown or m.button != mbLeft:
      return
    let hit = app.menu.hitTest(m.col, m.row)
    if hit.isSome:
      app.applyMenuAction(hit.get)
    else:
      app.menu.close()
    return

  if m.kind == mkDown and m.button == mbRight:
    if app.overlayOpen:
      return
    let tabIdx = app.tabIndexAt(m.col, m.row)
    if tabIdx >= 0:
      app.menu.openTabMenu(m.col, m.row, tabIdx)
    else:
      app.menu.openEditorMenu(m.col, m.row)
    return

  # Header audio buttons
  if app.panelRects.header.contains(m.col, m.row) and m.kind == mkDown and m.button == mbLeft:
    let pb = app.audio.playBtn
    let nb = app.audio.nextBtn
    if pb.w > 0 and m.col >= pb.x and m.col < pb.x + pb.w and m.row == pb.y:
      app.audio.toggle()
      app.setStatus(app.audio.statusLabel())
      return
    if nb.w > 0 and m.col >= nb.x and m.col < nb.x + nb.w and m.row == nb.y:
      app.audio.nextTrack()
      app.setStatus(app.audio.statusLabel())
      return

  # Tab bar clicks
  if m.kind == mkDown and m.button == mbLeft:
    let tabIdx = app.tabIndexAt(m.col, m.row)
    if tabIdx >= 0:
      app.tabs.selectTab(tabIdx)
      app.refreshOutlines()
      return

  # File tree
  let tree = app.fileTreeArea()
  if tree.contains(m.col, m.row) and m.kind == mkDown and m.button == mbLeft:
    app.focus = fpFileTree
    let innerY = m.row - tree.top - 1
    let idx = app.fileState.offset + innerY
    if idx == 0:
      app.cwd = parentDir(app.cwd)
      app.ai.workspace = app.cwd
      app.refreshFileTree()
      return
    let fileIdx = idx - 1
    if fileIdx >= 0 and fileIdx < app.fileEntries.len:
      app.fileState.select(idx)
      let e = app.fileEntries[fileIdx]
      if e.isDir:
        app.cwd = e.path
        app.ai.workspace = app.cwd
        app.refreshFileTree()
      else:
        app.openPath(e.path)
        app.focus = fpEditor
    return

  # Outlines
  let oa = app.outlinesArea()
  if not oa.isEmpty and oa.contains(m.col, m.row) and m.kind == mkDown:
    app.focus = fpOutlines
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

  # AI / bottom panel
  if app.panelRects.bottom.contains(m.col, m.row) and m.kind == mkDown and m.button == mbLeft:
    app.focus = fpAi
    return

  # Editor mouse
  let ed = app.panelRects.center
  if ed.contains(m.col, m.row):
    let inner = rect(ed.left + 1, ed.top + 1, max(0, ed.width.int - 2), max(0, ed.height.int - 2))
    if inner.contains(m.col, m.row):
      let visIdx = app.scrollY + (m.row - inner.top)
      let visualCol = m.col - inner.left
      var doc = app.tabs.current
      let visual = app.buildEditorVisual()
      var row = doc.cursor.row
      var col = doc.cursor.col
      if visIdx >= 0 and visIdx <= visual.high:
        let vr = visual[visIdx]
        row = vr.srcLine
        let line = doc.lines[row]
        let origin =
          if vr.hard: displayColAtByte(line, floorRuneIndex(line, app.scrollX))
          else: displayColAtByte(line, vr.startByte)
        col = byteAtDisplayCol(line, origin + visualCol)
        if not vr.hard:
          col = clamp(col, vr.startByte, max(vr.startByte, vr.endByte))
      if m.kind == mkDown and m.button == mbLeft:
        doc.setCursor(Cursor(row: row, col: col))
        doc.beginSelection()
        app.mouseSelecting = true
        app.tabs.docs[app.tabs.active] = doc
        app.updatePreferredCol()
        app.focus = fpEditor
      elif (m.kind == mkDown or m.kind == mkDrag) and app.mouseSelecting:
        doc.cursor = doc.clampCursor(Cursor(row: row, col: col))
        doc.updateSelectionHead()
        app.tabs.docs[app.tabs.active] = doc
        app.updatePreferredCol()
      elif m.kind == mkUp:
        app.mouseSelecting = false
      elif m.kind == mkScrollUp:
        app.scrollY = max(0, app.scrollY - 3)
      elif m.kind == mkScrollDown:
        let visual = app.buildEditorVisual()
        let maxScroll = max(0, visual.len - app.editorViewHeight())
        app.scrollY = min(maxScroll, app.scrollY + 3)

proc activateFileTreeSelection(app: var App) =
  let idx = app.fileState.selected.get(0)
  if idx == 0:
    app.cwd = parentDir(app.cwd)
    app.ai.workspace = app.cwd
    app.refreshFileTree()
    return
  let fileIdx = idx - 1
  if fileIdx >= 0 and fileIdx < app.fileEntries.len:
    let e = app.fileEntries[fileIdx]
    if e.isDir:
      app.cwd = e.path
      app.ai.workspace = app.cwd
      app.refreshFileTree()
    else:
      app.openPath(e.path)

proc handleSideKey(app: var App, key: KeyEvent) =
  case app.focus
  of fpFileTree:
    let maxIdx = app.fileEntries.len # includes ".." at 0
    case key.code
    of kcUp:
      let cur = app.fileState.selected.get(0)
      app.fileState.select(max(0, cur - 1))
    of kcDown:
      let cur = app.fileState.selected.get(0)
      app.fileState.select(min(maxIdx, cur + 1))
    of kcHome:
      app.fileState.select(0)
    of kcEnd:
      app.fileState.select(maxIdx)
    of kcPageUp:
      let cur = app.fileState.selected.get(0)
      app.fileState.select(max(0, cur - 10))
    of kcPageDown:
      let cur = app.fileState.selected.get(0)
      app.fileState.select(min(maxIdx, cur + 10))
    of kcEnter:
      app.activateFileTreeSelection()
    of kcEsc:
      app.focus = fpEditor
    else:
      discard
  of fpOutlines:
    if app.outlineItems.len == 0: return
    case key.code
    of kcUp:
      let cur = app.outlineState.selected.get(0)
      app.outlineState.select(max(0, cur - 1))
    of kcDown:
      let cur = app.outlineState.selected.get(0)
      app.outlineState.select(min(app.outlineItems.high, cur + 1))
    of kcHome:
      app.outlineState.select(0)
    of kcEnd:
      app.outlineState.select(app.outlineItems.high)
    of kcPageUp:
      let cur = app.outlineState.selected.get(0)
      app.outlineState.select(max(0, cur - 10))
    of kcPageDown:
      let cur = app.outlineState.selected.get(0)
      app.outlineState.select(min(app.outlineItems.high, cur + 10))
    of kcEnter:
      let idx = app.outlineState.selected.get(0)
      if idx >= 0 and idx < app.outlineItems.len:
        var doc = app.tabs.current
        doc.setCursor(Cursor(row: app.outlineItems[idx].line, col: 0))
        app.tabs.docs[app.tabs.active] = doc
        app.updatePreferredCol()
        let visual = app.buildEditorVisual()
        app.scrollY = max(0, visualIndexAt(visual, doc.cursor.row, 0) - 2)
        app.focus = fpEditor
    of kcEsc:
      app.focus = fpEditor
    else:
      discard
  else:
    discard

proc handleEvent*(app: var App, ev: Event) =
  case ev.kind
  of evKey:
    let key = ev.key
    if key.code == kcChar and kmCtrl in key.mods and key.rune.toUTF8.toLowerAscii == "q":
      app.quit = true
      return
    if app.confirmClose:
      case key.code
      of kcEsc:
        app.cancelConfirmClose()
      of kcLeft, kcUp:
        app.confirmSelected = max(0, app.confirmSelected - 1)
      of kcRight, kcDown, kcTab:
        app.confirmSelected = min(2, app.confirmSelected + 1)
      of kcHome:
        app.confirmSelected = 0
      of kcEnd:
        app.confirmSelected = 2
      of kcEnter:
        app.applyConfirmClose()
      of kcChar:
        let ch = key.rune.toUTF8.toLowerAscii
        if ch == "s":
          app.confirmSelected = 0
          app.applyConfirmClose()
        elif ch == "n":
          app.confirmSelected = 1
          app.applyConfirmClose()
        elif ch == "c":
          app.cancelConfirmClose()
      else:
        discard
      return
    if app.menu.visible:
      case key.code
      of kcEsc:
        app.menu.close()
      of kcUp:
        app.menu.selected = max(0, app.menu.selected - 1)
      of kcDown:
        app.menu.selected = min(app.menu.items.high, app.menu.selected + 1)
      of kcHome:
        app.menu.selected = 0
      of kcEnd:
        app.menu.selected = app.menu.items.high
      of kcEnter:
        app.applyMenuAction(app.menu.actionAt(app.menu.selected))
      else:
        discard
      return
    if key.code == kcChar and kmCtrl in key.mods and key.rune.toUTF8.toLowerAscii == "w":
      app.requestCloseTab(app.tabs.active)
      return
    if app.ai.busy and key.code == kcEsc:
      app.ai.requestCancel()
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
    # Panel focus cycle (Shift-Tab only — Tab stays available for editor indent)
    if key.code == kcBackTab or (key.code == kcTab and kmShift in key.mods):
      app.cycleFocus(1)
      return
    if app.focus == fpAi:
      case key.code
      of kcEsc:
        if app.ai.busy:
          app.ai.requestCancel()
        else:
          app.focus = fpEditor
      of kcEnter:
        let prompt = app.ai.input
        app.ai.input = ""
        if prompt.len > 0:
          app.ai.startAskAsync(prompt, app.bufferContext())
      of kcBackspace:
        if app.ai.input.len > 0:
          app.ai.input.setLen(app.ai.input.len - 1)
      of kcPageUp:
        app.ai.scroll = min(app.ai.messages.len, app.ai.scroll + 3)
      of kcPageDown:
        app.ai.scroll = max(0, app.ai.scroll - 3)
      of kcChar:
        if kmCtrl notin key.mods:
          app.ai.input.add key.rune.toUTF8
      else:
        discard
      return
    # Start command mode (Helix always; Vim only from NORMAL)
    if key.code == kcChar and key.rune.toUTF8 == ":" and kmCtrl notin key.mods and
        app.focus == fpEditor and
        (app.cfg.keymap != kmVim or app.editorMode == emNormal):
      app.commandMode = true
      app.commandLine = ""
      return
    if app.focus in {fpFileTree, fpOutlines}:
      app.handleSideKey(key)
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
    state[].audio.stop()
    state[].ai.mcp.shutdown()
    disableMouse()
    term.restore()
    app = state[]
  while not state.quit:
    discard state[].ai.pollAiEvents()
    state[].ai.pollOAuth()
    state[].audio.pollAlive()
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
