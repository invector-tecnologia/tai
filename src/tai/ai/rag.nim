## Workspace RAG: chunk files and retrieve by keyword overlap.

import std/[os, strutils, algorithm, times]

type
  Chunk* = object
    path*: string
    lineStart*: int
    text*: string
    terms*: seq[string]

  RagIndex* = object
    root*: string
    chunks*: seq[Chunk]
    indexedAt*: string

const MaxFileBytes = 256_000
const ChunkLines = 40

proc tokenize(s: string): seq[string] =
  var cur = ""
  for c in s.toLowerAscii:
    if c.isAlphaNumeric or c == '_':
      cur.add c
    else:
      if cur.len >= 3:
        result.add cur
      cur = ""
  if cur.len >= 3:
    result.add cur

proc shouldIndex(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii
  ext in [".nim", ".md", ".txt", ".yml", ".yaml", ".toml", ".json", ".xml",
          ".html", ".sh", ".py", ".rs", ".go", ".ts", ".js", ".env"]

proc reindex*(root: string): RagIndex =
  result.root = root
  result.indexedAt = $now()
  for path in walkDirRec(root):
    if not path.shouldIndex:
      continue
    if "/.git/" in path or "/nimcache/" in path:
      continue
    try:
      let info = getFileInfo(path)
      if info.size > MaxFileBytes:
        continue
      let lines = readFile(path).splitLines()
      var i = 0
      while i < lines.len:
        let stop = min(lines.high, i + ChunkLines - 1)
        let text = lines[i .. stop].join("\n")
        result.chunks.add Chunk(
          path: path,
          lineStart: i,
          text: text,
          terms: tokenize(text),
        )
        i = stop + 1
    except CatchableError:
      discard

proc score(chunk: Chunk, queryTerms: seq[string]): int =
  for t in queryTerms:
    if t in chunk.terms:
      inc result

proc retrieve*(index: RagIndex, query: string, limit = 4): seq[Chunk] =
  let q = tokenize(query)
  if q.len == 0 or index.chunks.len == 0:
    return
  var scored: seq[tuple[s: int, c: Chunk]]
  for c in index.chunks:
    let s = score(c, q)
    if s > 0:
      scored.add (s, c)
  scored.sort(proc(a, b: tuple[s: int, c: Chunk]): int = cmp(b.s, a.s))
  for i, pair in scored:
    if i >= limit: break
    result.add pair.c

proc formatContext*(chunks: seq[Chunk]): string =
  if chunks.len == 0:
    return ""
  var parts = @["# Retrieved workspace context"]
  for c in chunks:
    parts.add "## " & c.path & ":" & $(c.lineStart + 1)
    parts.add c.text
  parts.join("\n")
