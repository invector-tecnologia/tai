## inotify-based file watcher (Linux). Polls for external modifications.

import std/[os, tables, times]

type
  WatchEvent* = object
    path*: string
    mtime*: Time

  FileWatcher* = object
    watched*: Table[string, Time]
    dirty*: seq[string]

proc initFileWatcher*(): FileWatcher =
  FileWatcher(watched: initTable[string, Time]())

proc watch*(w: var FileWatcher, path: string) =
  if path.len == 0 or not fileExists(path):
    return
  w.watched[path] = getLastModificationTime(path)

proc unwatch*(w: var FileWatcher, path: string) =
  w.watched.del(path)

proc poll*(w: var FileWatcher): seq[string] =
  ## Returns paths whose mtime changed since last poll.
  result = @[]
  var toUpdate: seq[(string, Time)]
  for path, prev in w.watched.pairs:
    if not fileExists(path):
      continue
    let m = getLastModificationTime(path)
    if m != prev:
      result.add path
      toUpdate.add (path, m)
  for (path, m) in toUpdate:
    w.watched[path] = m
