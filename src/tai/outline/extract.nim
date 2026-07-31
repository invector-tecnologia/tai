## Outline extraction from document content.

import std/strutils
import ../highlight/engine
import ../buffer/document

type
  OutlineItem* = object
    label*: string
    line*: int
    depth*: int

proc extractOutlines*(doc: Document): seq[OutlineItem] =
  let lang = detectLang(doc.path)
  for i, line in doc.lines:
    let t = line.strip()
    if t.len == 0:
      continue
    case lang
    of langMarkdown:
      if t.startsWith("#"):
        var depth = 0
        while depth < t.len and t[depth] == '#':
          inc depth
        let label = t[depth .. ^1].strip()
        if label.len > 0:
          result.add OutlineItem(label: label, line: i, depth: depth)
    of langYaml, langToml, langEnv:
      if t.startsWith('#') or t.startsWith('-'):
        continue
      let colon = t.find(':')
      if colon > 0:
        var depth = 0
        for c in line:
          if c == ' ':
            inc depth
          elif c == '\t':
            depth += 2
          else:
            break
        result.add OutlineItem(label: t[0 ..< colon], line: i, depth: depth div 2)
    of langJson:
      let s = t.strip(chars = {',', '{', '}', '[', ']'})
      if s.startsWith('"'):
        let endq = s.find('"', 1)
        if endq > 1:
          result.add OutlineItem(label: s[1 ..< endq], line: i, depth: 0)
    of langXml, langHtml:
      if t.startsWith('<') and not t.startsWith("</") and not t.startsWith("<!--"):
        var name = t.strip(chars = {'<', '/', '>'})
        let sp = name.find(' ')
        if sp > 0:
          name = name[0 ..< sp]
        if name.len > 0:
          result.add OutlineItem(label: name, line: i, depth: 0)
    of langNim:
      if t.startsWith("proc ") or t.startsWith("func ") or t.startsWith("type ") or
          t.startsWith("template ") or t.startsWith("macro ") or t.startsWith("method "):
        result.add OutlineItem(label: t, line: i, depth: 0)
    else:
      if t.endsWith(':') or (t.startsWith("def ") or t.startsWith("class ") or
          t.startsWith("function ")):
        result.add OutlineItem(label: t, line: i, depth: 0)
  if result.len == 0 and doc.lines.len > 0:
    result.add OutlineItem(label: "(no symbols)", line: 0, depth: 0)
