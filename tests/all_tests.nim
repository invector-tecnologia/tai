import std/[os, strutils, options]
import ../src/tai/buffer/document
import ../src/tai/commands/dispatch
import ../src/tai/config
import ../src/tai/highlight/engine
import ../src/tai/outline/extract
import ../src/tai/preview/render
import ../src/tai/ai/[cache, rag]
import tatui
import tatui/core/rect

proc testDocument() =
  var d = fromText("hello\nworld", "t.txt")
  doAssert d.lineCount == 2
  d.setCursor(Cursor(row: 0, col: 5))
  d.insertText("!")
  doAssert d.lines[0] == "hello!"
  d.selectAll()
  doAssert d.selectedText().contains("hello!")
  d.deleteSelection()
  doAssert d.lines == @[""]
  echo "testDocument ok"

proc testCommands() =
  var cfg = defaultConfig()
  var doc = fromText("x", "/tmp/tai_test_doc.txt")
  var ctx = CommandContext(cfg: addr cfg, doc: addr doc)
  let r = dispatchCommand(ctx, ":hide outlines")
  doAssert r.ok
  doAssert cfg.outlinesVisible == false
  let r2 = dispatchCommand(ctx, ":show outlines")
  doAssert r2.ok
  doAssert cfg.outlinesVisible == true
  let r3 = dispatchCommand(ctx, ":set file_tree right")
  doAssert r3.ok
  doAssert cfg.fileTreeSide == ftsRight
  echo "testCommands ok"

proc testHighlight() =
  let h = highlightLine(langJson, """{"a": 1}""")
  doAssert h.spans.len > 0
  let md = highlightLine(langMarkdown, "# Title")
  doAssert md.spans[0].kind == tkHeader
  let range = highlightRange(langNim, @["proc foo() = discard", "let x = 1"], 0, 1)
  doAssert range.len == 2
  echo "testHighlight ok"

proc testOutlinePreview() =
  let doc = fromText("# A\n\n## B\ntext", "x.md")
  let o = extractOutlines(doc)
  doAssert o.len >= 2
  let prev = renderMarkdownPreview(doc.lines)
  doAssert prev.len > 0
  doAssert canPreview("x.md")
  echo "testOutlinePreview ok"

proc testCacheRag() =
  var pc = initPromptCache()
  pc.put("k", "v")
  doAssert isSome(pc.get("k"))
  doAssert pc.get("k").get() == "v"
  doAssert estimateTokens("abcd") == 1
  let idx = reindex(getCurrentDir())
  discard retrieve(idx, "tai editor")
  echo "testCacheRag ok chunks=" & $idx.chunks.len

proc testLayoutSmoke() =
  let area = rect(0, 0, 120, 40)
  let rows = area.split(Vertical, @[length(1), fill(1), length(8)])
  doAssert rows.len == 3
  let cols = rows[1].split(Horizontal, @[length(28), fill(1), length(28)])
  doAssert cols.len == 3
  echo "testLayoutSmoke ok"

when isMainModule:
  testDocument()
  testCommands()
  testHighlight()
  testOutlinePreview()
  testCacheRag()
  testLayoutSmoke()
  echo "all tests passed"
