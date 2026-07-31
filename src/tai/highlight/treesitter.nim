## Tree-sitter highlight backend with regex fallback.

import std/[os, osproc, strutils, options]
import ../config
import ./engine

proc treeSitterAvailable*: bool =
  findExe("tree-sitter").len > 0

proc highlightWithTreeSitterCli(source, langHint: string): Option[seq[HighlightedLine]] =
  ## Best-effort: if tree-sitter CLI is present, we still fall back to regex
  ## for span mapping (CLI HTML output is awkward to map). Returns none to
  ## signal fallback — reserved for future native bindings.
  discard source
  discard langHint
  if not treeSitterAvailable():
    return none(seq[HighlightedLine])
  none(seq[HighlightedLine])

proc highlightRangeAuto*(
    engine: HighlightEngine,
    lang: LangId,
    lines: seq[string],
    startLine, endLine: int,
): seq[HighlightedLine] =
  case engine
  of heRegex:
    highlightRange(lang, lines, startLine, endLine)
  of heTreeSitter:
    let joined = lines[startLine .. endLine].join("\n")
    let ts = highlightWithTreeSitterCli(joined, $lang)
    if ts.isSome:
      ts.get
    else:
      highlightRange(lang, lines, startLine, endLine)
  of heAuto:
    if treeSitterAvailable():
      let joined = lines[startLine .. min(endLine, lines.high)].join("\n")
      let ts = highlightWithTreeSitterCli(joined, $lang)
      if ts.isSome:
        return ts.get
    highlightRange(lang, lines, startLine, endLine)
