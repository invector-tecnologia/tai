## Colon-command parser and dispatch (:q, :w, Helix-style).

import std/[strutils, os]
import ../config
import ../buffer/document
import ../fs/io

type
  CommandResult* = object
    ok*: bool
    message*: string
    quit*: bool
    redraw*: bool
    newCwd*: string       ## non-empty → app should refresh file tree
    openPath*: string     ## non-empty → app should open via openPath
    aiCmd*: string        ## non-empty → AI command payload (without prefix)

  CommandContext* = object
    cfg*: ptr Config
    doc*: ptr Document
    status*: string

proc okResult(msg: string, quit = false): CommandResult =
  CommandResult(ok: true, message: msg, quit: quit, redraw: true)

proc errResult(msg: string): CommandResult =
  CommandResult(ok: false, message: msg, quit: false, redraw: true)

proc dispatchCommand*(ctx: var CommandContext, raw: string): CommandResult =
  let line = raw.strip()
  if line.len == 0:
    return okResult("")
  var cmd = line
  if cmd.startsWith(':'):
    cmd = cmd[1 .. ^1].strip()
  let parts = cmd.splitWhitespace()
  if parts.len == 0:
    return okResult("")
  let head = parts[0].toLowerAscii
  let args = if parts.len > 1: parts[1 .. ^1] else: @[]

  case head
  of "q", "quit":
    if ctx.doc[].dirty:
      return errResult("unsaved changes — use :q! or :wq")
    return okResult("bye", quit = true)
  of "q!":
    return okResult("bye", quit = true)
  of "w", "write":
    if args.len > 0:
      ctx.doc[].path = args[0].expandTilde.absolutePath
    let (ok, err) = saveFile(ctx.doc[])
    if ok: return okResult("written: " & ctx.doc[].path)
    else: return errResult(err)
  of "wq", "x":
    let (ok, err) = saveFile(ctx.doc[])
    if not ok: return errResult(err)
    return okResult("written", quit = true)
  of "e", "edit", "open":
    if args.len == 0:
      return errResult("usage: :e <path>")
    var r = okResult("open")
    r.openPath = args[0].expandTilde.absolutePath
    return r
  of "hide", "show":
    const panelItems = "outlines, files"
    if args.len == 0:
      return okResult("select: " & panelItems & "  (e.g. :" & head & " outlines)")
    let visible = head == "show"
    let item = args[0].toLowerAscii
    case item
    of "outlines", "outline":
      ctx.cfg[].outlinesVisible = visible
      return okResult(if visible: "outlines shown" else: "outlines hidden")
    of "arquivos", "arquivo", "files", "file":
      ctx.cfg[].filesVisible = visible
      return okResult(if visible: "files shown" else: "files hidden")
    else:
      return errResult("invalid item — select: " & panelItems)
  of "preview":
    ctx.cfg[].previewMode = true
    ctx.doc[].previewMode = true
    return okResult("preview mode")
  of "source":
    ctx.cfg[].previewMode = false
    ctx.doc[].previewMode = false
    return okResult("source mode")
  of "set":
    if args.len < 2:
      return errResult("usage: :set file_tree left|right")
    if args[0] == "file_tree":
      case args[1].toLowerAscii
      of "left":
        ctx.cfg[].fileTreeSide = ftsLeft
        return okResult("file tree: left")
      of "right":
        ctx.cfg[].fileTreeSide = ftsRight
        return okResult("file tree: right")
      else:
        return errResult("expected left|right")
    return errResult("unknown setting")
  of "cd":
    if args.len == 0:
      return errResult("usage: :cd <path>")
    let p = args[0].expandTilde.absolutePath
    if not dirExists(p):
      return errResult("not a directory")
    ctx.cfg[].workspace = p
    setCurrentDir(p)
    var r = okResult("cwd: " & p)
    r.newCwd = p
    return r
  of "help":
    return okResult(
      ":q :w :wq :e :hide/:show [outlines|files] :preview :source " &
      ":set file_tree left|right :cd :ai :login :provider :model :rag :shell :audio"
    )
  else:
    if head in ["ai", "login", "provider", "model", "rag", "shell", "clear", "audio"]:
      var r = okResult("")
      r.aiCmd = cmd
      return r
    return errResult("unknown command: :" & head)
