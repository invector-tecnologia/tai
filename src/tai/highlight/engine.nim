## Incremental regex/rule-based syntax highlighter (tree-sitter-ready interface).

import std/[os, strutils, sets, unicode]
import tatui
import tatui/core/style
import ../theme

type
  TokenKind* = enum
    tkPlain
    tkKeyword
    tkString
    tkComment
    tkNumber
    tkPunct
    tkHeader
    tkKey
    tkType
    tkFunction

  TokenSpan* = object
    start*, finish*: int ## Byte offsets into the line (UTF-8 safe; never mid-rune).
    kind*: TokenKind

  HighlightedLine* = object
    spans*: seq[TokenSpan]

  LangId* = enum
    langPlain
    langMarkdown
    langYaml
    langToml
    langXml
    langHtml
    langJson
    langShell
    langNim
    langDockerfile
    langMakefile
    langEnv

proc detectLang*(path: string): LangId =
  let ext = path.splitFile.ext.toLowerAscii
  let base = path.extractFilename.toLowerAscii
  case base
  of "dockerfile":
    return langDockerfile
  of "makefile", "gnumakefile":
    return langMakefile
  of ".env", ".env.local", ".env.example":
    return langEnv
  else:
    discard
  case ext
  of ".md", ".markdown":
    langMarkdown
  of ".yml", ".yaml":
    langYaml
  of ".toml":
    langToml
  of ".xml", ".svg":
    langXml
  of ".html", ".htm":
    langHtml
  of ".json", ".jsonc":
    langJson
  of ".sh", ".bash", ".zsh":
    langShell
  of ".nim", ".nims", ".nimble":
    langNim
  of ".env":
    langEnv
  else:
    langPlain

proc tokenStyle*(kind: TokenKind): Style =
  case kind
  of tkPlain:
    tnFg(Tn.fg)
  of tkKeyword:
    tnFg(Tn.magenta, {mBold})
  of tkString:
    tnFg(Tn.green)
  of tkComment:
    tnFg(Tn.comment, {mItalic})
  of tkNumber:
    tnFg(Tn.cyan)
  of tkPunct:
    tnFg(Tn.comment)
  of tkHeader:
    tnFg(Tn.blue, {mBold})
  of tkKey:
    tnFg(Tn.yellow)
  of tkType:
    tnFg(Tn.cyan)
  of tkFunction:
    tnFg(Tn.orange)

proc addSpan(spans: var seq[TokenSpan], start, finish: int, kind: TokenKind) =
  if finish > start:
    spans.add TokenSpan(start: start, finish: finish, kind: kind)

proc advanceRune(s: string, i: var int) =
  ## Advance `i` by one full UTF-8 rune (clamped; always progresses).
  if i < s.len:
    let n = min(runeLenAt(s, i), s.len - i)
    i += max(1, n)

proc addPlainRune(spans: var seq[TokenSpan], s: string, i: var int) =
  let start = i
  advanceRune(s, i)
  addSpan(spans, start, i, tkPlain)

proc isWordRune(r: Rune): bool =
  if r.isAlpha or r == Rune('_'):
    return true
  let c = r.int32
  c >= ord('0') and c <= ord('9')

const
  NimKeywords = [
    "proc", "func", "method", "iterator", "template", "macro", "type", "const", "let",
    "var", "import", "from", "export", "include", "if", "elif", "else", "when", "case",
    "of", "for", "while", "block", "return", "yield", "break", "continue", "nil", "true",
    "false", "and", "or", "not", "xor", "div", "mod", "in", "notin", "is", "isnot",
    "object", "enum", "ref", "ptr", "seq", "string", "int", "bool", "float", "discard",
    "try", "except", "finally", "raise", "defer", "async", "await",
  ].toHashSet()

  ShellKeywords = [
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
    "function", "return", "export", "local", "readonly", "source", "alias", "echo",
    "cd", "exit", "set", "unset", "shift",
  ].toHashSet()

  DockerfileKeywords = [
    "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT",
    "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL",
  ].toHashSet()

proc highlightKeywords(line: string, keywords: HashSet[string], commentPrefix = "#"): HighlightedLine =
  var i = 0
  while i < line.len:
    if commentPrefix.len > 0 and i + commentPrefix.len <= line.len and
        line[i ..< i + commentPrefix.len] == commentPrefix:
      addSpan(result.spans, i, line.len, tkComment)
      break
    let c = line[i]
    if c in {'"', '\''}:
      let q = c
      var j = i + 1
      while j < line.len and line[j] != q:
        if line[j] == '\\' and j + 1 < line.len:
          inc j
        inc j
      if j < line.len:
        inc j
      addSpan(result.spans, i, j, tkString)
      i = j
    elif c.isDigit:
      var j = i
      while j < line.len and (line[j].isDigit or line[j] == '.'):
        inc j
      addSpan(result.spans, i, j, tkNumber)
      i = j
    elif c.isAlphaAscii or c == '_' or isWordRune(line.runeAt(i)):
      var j = i
      while j < line.len and isWordRune(line.runeAt(j)):
        advanceRune(line, j)
      let word = line[i ..< j]
      let kind = if word in keywords: tkKeyword else: tkPlain
      addSpan(result.spans, i, j, kind)
      i = j
    elif c in "{}[](),:;=<>!&|+-*/%":
      addSpan(result.spans, i, i + 1, tkPunct)
      inc i
    else:
      addPlainRune(result.spans, line, i)

proc highlightMarkdown(line: string): HighlightedLine =
  let t = strutils.strip(line, trailing = false)
  if t.startsWith("#"):
    addSpan(result.spans, 0, line.len, tkHeader)
  elif t.startsWith("```") or t.startsWith("---"):
    addSpan(result.spans, 0, line.len, tkPunct)
  elif t.startsWith(">") or t.startsWith("- ") or t.startsWith("* "):
    addSpan(result.spans, 0, line.len, tkKeyword)
  else:
    var i = 0
    while i < line.len:
      if line[i] == '`':
        var j = i + 1
        while j < line.len and line[j] != '`':
          inc j
        if j < line.len:
          inc j
        addSpan(result.spans, i, j, tkString)
        i = j
      else:
        addPlainRune(result.spans, line, i)

proc highlightYamlLike(line: string, comment = "#"): HighlightedLine =
  let stripped = strutils.strip(line, trailing = false)
  if stripped.startsWith(comment):
    addSpan(result.spans, 0, line.len, tkComment)
    return
  let colon = line.find(':')
  if colon > 0 and not strutils.strip(line).startsWith('-'):
    addSpan(result.spans, 0, colon, tkKey)
    addSpan(result.spans, colon, colon + 1, tkPunct)
    if colon + 1 < line.len:
      let rest = line[colon + 1 .. ^1]
      let rs = strutils.strip(rest, trailing = false)
      if rs.startsWith('"') or rs.startsWith('\''):
        addSpan(result.spans, colon + 1, line.len, tkString)
      elif rs.len > 0 and rs[0].isDigit:
        addSpan(result.spans, colon + 1, line.len, tkNumber)
      else:
        addSpan(result.spans, colon + 1, line.len, tkPlain)
  else:
    result = highlightKeywords(line, initHashSet[string](), comment)

proc highlightJson(line: string): HighlightedLine =
  var i = 0
  while i < line.len:
    let c = line[i]
    if c == '"':
      var j = i + 1
      while j < line.len and line[j] != '"':
        if line[j] == '\\' and j + 1 < line.len:
          inc j
        inc j
      if j < line.len:
        inc j
      var kind = tkString
      var k = j
      while k < line.len and line[k] in Whitespace:
        inc k
      if k < line.len and line[k] == ':':
        kind = tkKey
      addSpan(result.spans, i, j, kind)
      i = j
    elif c.isDigit or (c == '-' and i + 1 < line.len and line[i + 1].isDigit):
      var j = i + 1
      while j < line.len and (line[j].isDigit or line[j] in {'.', 'e', 'E', '+', '-'}):
        inc j
      addSpan(result.spans, i, j, tkNumber)
      i = j
    elif c in "{}[],:":
      addSpan(result.spans, i, i + 1, tkPunct)
      inc i
    elif line.continuesWith("true", i) or line.continuesWith("false", i) or
        line.continuesWith("null", i):
      let word =
        if line.continuesWith("true", i): "true"
        elif line.continuesWith("false", i): "false"
        else: "null"
      addSpan(result.spans, i, i + word.len, tkKeyword)
      i += word.len
    else:
      addPlainRune(result.spans, line, i)

proc highlightXml(line: string): HighlightedLine =
  var i = 0
  while i < line.len:
    if line[i] == '<':
      var j = i + 1
      while j < line.len and line[j] != '>':
        inc j
      if j < line.len:
        inc j
      addSpan(result.spans, i, j, tkKeyword)
      i = j
    elif line[i] == '"':
      var j = i + 1
      while j < line.len and line[j] != '"':
        inc j
      if j < line.len:
        inc j
      addSpan(result.spans, i, j, tkString)
      i = j
    else:
      addPlainRune(result.spans, line, i)

proc highlightLine*(lang: LangId, line: string): HighlightedLine =
  case lang
  of langPlain:
    addSpan(result.spans, 0, line.len, tkPlain)
  of langMarkdown:
    result = highlightMarkdown(line)
  of langYaml, langToml, langEnv:
    result = highlightYamlLike(line)
  of langJson:
    result = highlightJson(line)
  of langXml, langHtml:
    result = highlightXml(line)
  of langNim:
    result = highlightKeywords(line, NimKeywords, "#")
  of langShell:
    result = highlightKeywords(line, ShellKeywords, "#")
  of langDockerfile:
    result = highlightKeywords(line, DockerfileKeywords, "#")
  of langMakefile:
    result = highlightKeywords(line, ["ifeq", "endif", "include", "export"].toHashSet(), "#")

proc highlightRange*(
    lang: LangId, lines: openArray[string], startLine, endLine: int
): seq[HighlightedLine] =
  ## Highlight only the visible viewport range (streaming-friendly).
  let a = max(0, startLine)
  let b = min(lines.high, endLine)
  for i in a .. b:
    result.add highlightLine(lang, lines[i])
