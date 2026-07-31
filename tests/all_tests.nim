import std/[os, strutils, options]
import ../src/tai/buffer/document
import ../src/tai/commands/dispatch
import ../src/tai/config
import ../src/tai/highlight/engine
import ../src/tai/outline/extract
import ../src/tai/preview/render
import ../src/tai/ai/[cache, rag, tools]
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
  let prev = getCurrentDir()
  var cfg = defaultConfig()
  var doc = fromText("x", "/tmp/tai_test_doc.txt")
  var ctx = CommandContext(cfg: addr cfg, doc: addr doc)
  let listed = dispatchCommand(ctx, ":hide")
  doAssert listed.ok
  doAssert listed.message.contains("outlines")
  doAssert listed.message.contains("files")
  let r = dispatchCommand(ctx, ":hide outlines")
  doAssert r.ok
  doAssert cfg.outlinesVisible == false
  let rFiles = dispatchCommand(ctx, ":hide files")
  doAssert rFiles.ok
  doAssert cfg.filesVisible == false
  let rAlias = dispatchCommand(ctx, ":show arquivos")
  doAssert rAlias.ok
  doAssert cfg.filesVisible == true
  let r2 = dispatchCommand(ctx, ":show outlines")
  doAssert r2.ok
  doAssert cfg.outlinesVisible == true
  let r4 = dispatchCommand(ctx, ":set file_tree right")
  doAssert r4.ok
  doAssert cfg.fileTreeSide == ftsRight
  let rCd = dispatchCommand(ctx, ":cd /tmp")
  doAssert rCd.ok
  doAssert rCd.newCwd.len > 0
  setCurrentDir(prev)
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

proc testTools() =
  let root = getCurrentDir()
  let listed = toolListDir(root, ".")
  doAssert listed.ok
  let readme = toolReadFile(root, "README.md")
  doAssert readme.ok
  doAssert readme.output.contains("Tai")
  let blocked = toolShell("echo hi", allowed = false)
  doAssert blocked.needsApproval
  echo "testTools ok"

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
  testTools()
  testLayoutSmoke()
  echo "all tests passed"
