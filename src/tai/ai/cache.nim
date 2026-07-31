## Token / prompt / semantic / context caches + simple embedding hash.

import std/[os, strutils, tables, times, hashes, json, base64, options]

type
  CacheEntry* = object
    key*: string
    value*: string
    created*: Time
    hits*: int

  PromptCache* = object
    entries*: Table[string, CacheEntry]

  ContextCache* = object
    summary*: string
    transcriptTail*: seq[string]

  SemanticCache* = object
    path*: string
    entries*: Table[string, CacheEntry]

  TokenStats* = object
    promptTokens*: int
    completionTokens*: int
    savedTokens*: int
    rtkSavedTokens*: int

proc initPromptCache*(): PromptCache =
  PromptCache(entries: initTable[string, CacheEntry]())

proc initContextCache*(): ContextCache =
  ContextCache(transcriptTail: @[])

proc initSemanticCache*(path: string): SemanticCache =
  result = SemanticCache(path: path, entries: initTable[string, CacheEntry]())
  if fileExists(path):
    try:
      let j = parseJson(readFile(path))
      for k, v in j.pairs:
        result.entries[k] = CacheEntry(key: k, value: v.getStr, created: getTime(), hits: 0)
    except CatchableError:
      discard

proc save*(c: SemanticCache) =
  let parent = parentDir(c.path)
  if parent.len > 0:
    createDir(parent)
  var j = newJObject()
  for k, e in c.entries:
    j[k] = %e.value
  writeFile(c.path, $j)

proc estimateTokens*(text: string): int =
  max(1, text.len div 4)

proc cacheKey*(text: string): string =
  encode($hash(text))

proc get*(c: var PromptCache, key: string): Option[string] =
  if c.entries.hasKey(key):
    inc c.entries[key].hits
    return some(c.entries[key].value)
  none(string)

proc put*(c: var PromptCache, key, value: string) =
  c.entries[key] = CacheEntry(key: key, value: value, created: getTime(), hits: 0)

proc get*(c: var SemanticCache, prompt: string): Option[string] =
  let key = cacheKey(prompt)
  if c.entries.hasKey(key):
    inc c.entries[key].hits
    return some(c.entries[key].value)
  none(string)

proc put*(c: var SemanticCache, prompt, response: string) =
  let key = cacheKey(prompt)
  c.entries[key] = CacheEntry(key: key, value: response, created: getTime(), hits: 0)
  c.save()

proc appendTurn*(c: var ContextCache, role, content: string) =
  c.transcriptTail.add role & ": " & content
  if c.transcriptTail.len > 40:
    let head = c.transcriptTail[0 ..< c.transcriptTail.len - 30]
    c.summary = "Earlier conversation (" & $head.len & " turns) compacted."
    c.transcriptTail = c.transcriptTail[^30 .. ^1]

proc contextBlock*(c: ContextCache): string =
  var parts: seq[string]
  if c.summary.len > 0:
    parts.add c.summary
  for t in c.transcriptTail:
    parts.add t
  parts.join("\n")
