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

proc detectLineEnding(data: string): string =
  if data.contains("\r\n"): "\r\n" else: "\n"

proc loadFile*(path: string): LoadResult =
  let t0 = cpuTime()
  try:
    if not fileExists(path):
      return LoadResult(ok: false, error: "file not found: " & path)
    let data = readFile(path)
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
