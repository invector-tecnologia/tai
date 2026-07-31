## Tab manager for multiple open documents.

import std/os
import ./document

type
  TabManager* = object
    docs*: seq[Document]
    active*: int

proc initTabManager*(): TabManager =
  result.docs = @[emptyDocument()]
  result.active = 0

proc current*(tm: var TabManager): var Document =
  tm.docs[tm.active]

proc current*(tm: TabManager): Document =
  tm.docs[tm.active]

proc titles*(tm: TabManager): seq[string] =
  for d in tm.docs:
    result.add d.displayName()

proc openDoc*(tm: var TabManager, doc: Document) =
  # Reuse existing tab for same path
  if doc.path.len > 0:
    for i, d in tm.docs:
      if d.path == doc.path:
        tm.active = i
        return
  if tm.docs.len == 1 and tm.docs[0].path.len == 0 and not tm.docs[0].dirty and
      tm.docs[0].lines == @[""]:
    tm.docs[0] = doc
    tm.active = 0
  else:
    tm.docs.add doc
    tm.active = tm.docs.high

proc closeTab*(tm: var TabManager, index: int): bool =
  ## Returns false if last tab was closed and replaced with scratch.
  if index < 0 or index >= tm.docs.len:
    return true
  if tm.docs.len <= 1:
    tm.docs[0] = emptyDocument()
    tm.active = 0
    return false
  tm.docs.delete(index)
  if tm.active > index:
    dec tm.active
  elif tm.active >= tm.docs.len:
    tm.active = tm.docs.high
  true

proc closeActive*(tm: var TabManager): bool =
  tm.closeTab(tm.active)

proc duplicateTab*(tm: var TabManager, index: int) =
  if index < 0 or index >= tm.docs.len:
    return
  let src = tm.docs[index]
  let base =
    if src.path.len == 0: "scratch"
    else: src.path.extractFilename
  var copy = src
  copy.path = "copy-" & base
  copy.dirty = true
  let insertAt = index + 1
  tm.docs.insert(copy, insertAt)
  tm.active = insertAt

proc selectTab*(tm: var TabManager, i: int) =
  if i >= 0 and i < tm.docs.len:
    tm.active = i

proc nextTab*(tm: var TabManager) =
  if tm.docs.len == 0: return
  tm.active = (tm.active + 1) mod tm.docs.len

proc prevTab*(tm: var TabManager) =
  if tm.docs.len == 0: return
  tm.active = (tm.active - 1 + tm.docs.len) mod tm.docs.len
