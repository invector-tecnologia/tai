## Filesystem helpers: load/save with streaming metrics.

import std/[os, strutils, times, algorithm]
import ../buffer/document

type
  DirEntry* = object
    name*: string
    isDir*: bool
    path*: string

  LoadResult* = object
    doc*: Document
    elapsedMs*: float
    ok*: bool
    error*: string
    ## When true, caller should not open an empty tab (e.g. binary file).
    refuse*: bool

proc detectLineEnding(data: string): string =
  if data.contains("\r\n"): "\r\n" else: "\n"

proc looksBinary*(data: string, path = ""): bool =
  ## Heuristic: known binary extensions/magic, NUL, or many control bytes.
  let ext = path.splitFile.ext.toLowerAscii
  if ext in [".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp",
             ".zip", ".gz", ".bz2", ".xz", ".7z", ".rar", ".tar",
             ".woff", ".woff2", ".ttf", ".otf", ".eot",
             ".mp3", ".mp4", ".wav", ".ogg", ".webm", ".mkv",
             ".exe", ".dll", ".so", ".dylib", ".o", ".a",
             ".class", ".pyc", ".wasm", ".bin", ".dat"]:
    return true
  if data.startsWith("%PDF") or data.startsWith("\x89PNG") or
      data.startsWith("\xff\xd8\xff") or data.startsWith("GIF8") or
      data.startsWith("PK\x03\x04") or data.startsWith("\x7fELF"):
    return true
  let n = min(data.len, 8192)
  if n == 0:
    return false
  var weird = 0
  for i in 0 ..< n:
    let c = data[i].uint8
    if c == 0:
      return true
    # C0 controls except TAB/LF/CR
    if c < 32 and c notin [9'u8, 10, 13]:
      inc weird
  weird * 10 > n # >10% control bytes

proc loadFile*(path: string): LoadResult =
  let t0 = cpuTime()
  try:
    if not fileExists(path):
      return LoadResult(ok: false, error: "file not found: " & path)
    let data = readFile(path)
    if looksBinary(data, path):
      return LoadResult(
        ok: false,
        refuse: true,
        error: "binary file (not opened as text): " & path.extractFilename,
        elapsedMs: (cpuTime() - t0) * 1000,
      )
    var doc = fromText(data, path)
    doc.lineEnding = detectLineEnding(data)
    doc.bytesLoaded = data.len
    result = LoadResult(doc: doc, ok: true, elapsedMs: (cpuTime() - t0) * 1000)
  except CatchableError as e:
    result = LoadResult(ok: false, error: e.msg, elapsedMs: (cpuTime() - t0) * 1000)

proc saveFile*(doc: var Document): tuple[ok: bool, error: string] =
  if doc.path.len == 0:
    return (false, "no path set")
  try:
    let parent = parentDir(doc.path)
    if parent.len > 0:
      createDir(parent)
    writeFile(doc.path, doc.text())
    doc.dirty = false
    (true, "")
  except CatchableError as e:
    (false, e.msg)

proc listDirEntries*(dir: string): seq[DirEntry] =
  result = @[]
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if name.startsWith('.'):
      continue
    case kind
    of pcDir, pcLinkToDir:
      result.add DirEntry(name: name & "/", isDir: true, path: path)
    of pcFile, pcLinkToFile:
      result.add DirEntry(name: name, isDir: false, path: path)
  result.sort(proc(a, b: DirEntry): int =
    if a.isDir != b.isDir:
      return if a.isDir: -1 else: 1
    cmpIgnoreCase(a.name, b.name)
  )
