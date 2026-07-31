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
    let path = args[0].expandTilde.absolutePath
    let loaded = loadFile(path)
    if not loaded.ok:
      # create new file buffer
      ctx.doc[] = emptyDocument(path)
      return okResult("new: " & path)
    ctx.doc[] = loaded.doc
    return okResult("opened: " & path & " (" & $loaded.doc.bytesLoaded & " bytes)")
  of "hide":
    if args.len > 0 and args[0].toLowerAscii == "outlines":
      ctx.cfg[].outlinesVisible = false
      return okResult("outlines hidden")
    return errResult("usage: :hide outlines")
  of "show":
    if args.len > 0 and args[0].toLowerAscii == "outlines":
      ctx.cfg[].outlinesVisible = true
      return okResult("outlines shown")
    return errResult("usage: :show outlines")
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
    if args[0] == "keymap":
      case args[1].toLowerAscii
      of "helix":
        ctx.cfg[].keymap = kmHelix
        return okResult("keymap: helix")
      of "vim":
        ctx.cfg[].keymap = kmVim
        return okResult("keymap: vim")
      else:
        return errResult("expected helix|vim")
    return errResult("unknown setting")
  of "cd":
    if args.len == 0:
      return errResult("usage: :cd <path>")
    let p = args[0].expandTilde.absolutePath
    if not dirExists(p):
      return errResult("not a directory")
    ctx.cfg[].workspace = p
    setCurrentDir(p)
    return okResult("cwd: " & p)
  of "help":
    return okResult(":q :w :wq :e :hide outlines :show outlines :preview :source :set file_tree left|right :ai :login :provider :rag")
  else:
    # AI-related commands handled by app layer via prefix
    if head in ["ai", "login", "provider", "rag"]:
      return CommandResult(ok: true, message: "AI_CMD:" & cmd, quit: false, redraw: true)
    return errResult("unknown command: :" & head)
