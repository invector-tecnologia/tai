import std/[os, strutils, options]
import ../src/tai/buffer/document
import ../src/tai/buffer/tabs
import ../src/tai/buffer/wrap
import ../src/tai/commands/dispatch
import ../src/tai/config
import ../src/tai/highlight/engine
import ../src/tai/outline/extract
import ../src/tai/preview/render
import ../src/tai/ai/[cache, rag, tools, sse]
import ../src/tai/config
import ../src/tai/git/cmd
import ../src/tai/theme
import ../src/tai/fs/io
import ../src/tai/ui/utf8clip
import ../src/tai/app as taiapp
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

proc testTabs() =
  var tm = initTabManager()
  tm.openDoc(fromText("one", "/tmp/a.txt"))
  tm.openDoc(fromText("two", "/tmp/b.txt"))
  doAssert tm.docs.len == 2
  tm.duplicateTab(0)
  doAssert tm.docs.len == 3
  doAssert tm.active == 1
  doAssert tm.docs[1].path == "copy-a.txt"
  doAssert tm.docs[1].dirty
  doAssert tm.docs[1].lines == @["one"]
  doAssert tm.closeTab(1)
  doAssert tm.docs.len == 2
  discard tm.closeTab(0)
  discard tm.closeTab(0)
  doAssert tm.docs.len == 1
  doAssert tm.docs[0].path.len == 0
  echo "testTabs ok"

proc testWrap() =
  doAssert shouldSoftWrap("hello world", false)
  doAssert not shouldSoftWrap("| a | b |", false)
  doAssert not shouldSoftWrap("```nim", false)
  doAssert not shouldSoftWrap("code here", true)
  let prose = "word " & repeat("longword ", 20)
  let rows = buildVisualRows(@[prose], 20)
  doAssert rows.len > 1
  let table = buildVisualRows(@["| a | b | c |"], 10)
  doAssert table.len == 1
  doAssert table[0].hard
  let fenced = buildVisualRows(@["```", "a very long line that would wrap if prose", "```"], 10)
  doAssert fenced.len == 3
  doAssert fenced[1].hard
  doAssert fenced[1].endByte == "a very long line that would wrap if prose".len
  # Invalid UTF-8 continuation bytes must not crash (PDF-like lines)
  let binaryRows = buildVisualRows(@["\x80\x80", "\xff\xfe| a |", "%PDF-1.4"], 40)
  doAssert binaryRows.len == 3
  echo "testWrap ok"

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
  # UTF-8 must not be split mid-rune (scroll/ghost glyph bug)
  let utf = "Documentação contém visão"
  let utfHl = highlightLine(langMarkdown, utf)
  var rebuilt = ""
  for sp in utfHl.spans:
    doAssert sp.start >= 0 and sp.finish <= utf.len
    doAssert sp.start < sp.finish
    doAssert (utf[sp.start].uint8 and 0xC0'u8) != 0x80'u8 # not a continuation byte
    rebuilt.add utf[sp.start ..< sp.finish]
  doAssert rebuilt == utf
  echo "testHighlight ok"

proc testUtf8Clip() =
  let s = "ação"
  doAssert floorRuneIndex(s, 2) == 1 # mid-byte of ç → start of ç
  doAssert clipToDisplayWidth(s, 2) == "aç"
  doAssert clipToDisplayWidth("hello", 3) == "hel"
  doAssert displayColAtByte(s, byteAtDisplayCol(s, 2)) == 2
  # Incomplete UTF-8 must not IndexDefect
  let bad = "hello" & "\xC3"
  doAssert safeRuneLen(bad, bad.len - 1) == 1
  var i = 0
  while i < bad.len:
    let n = safeRuneLen(bad, i)
    discard bad[i ..< i + n]
    i += n
  echo "testUtf8Clip ok"

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
  doAssert toolAllowed(amPlan, "read_file")
  doAssert not toolAllowed(amPlan, "write_file")
  doAssert toolAllowed(amAgent, "shell")
  echo "testTools ok"

proc testSseGitTheme() =
  let noneLine = parseSseDataLine(": ping")
  doAssert noneLine.isNone
  let done = parseSseDataLine("data: [DONE]")
  doAssert done.isNone
  let chunk = parseSseDataLine("""data: {"choices":[{"delta":{"content":"hi"}}]}""")
  doAssert chunk.isSome
  doAssert deltaContent(chunk.get) == "hi"
  let gs = gitStatus(getCurrentDir())
  discard gs.ok
  setTheme(thGruvboxDark)
  doAssert ActiveId == thGruvboxDark
  setTheme(thTokyoNight)
  doAssert parseMode("plan") == amPlan
  echo "testSseGitTheme ok"

proc testLayoutSmoke() =
  let area = rect(0, 0, 120, 40)
  let rows = area.split(Vertical, @[length(1), fill(1), length(8)])
  doAssert rows.len == 3
  let cols = rows[1].split(Horizontal, @[length(28), fill(1), length(28)])
  doAssert cols.len == 3
  echo "testLayoutSmoke ok"

proc testFocusCycle() =
  var cfg = defaultConfig()
  cfg.audio.autoplay = false
  cfg.filesVisible = true
  cfg.outlinesVisible = true
  var app = initApp(cfg)
  doAssert app.focusRing() == @[fpEditor, fpFileTree, fpOutlines, fpAi]
  doAssert app.focus == fpEditor
  app.cycleFocus(1)
  doAssert app.focus == fpFileTree
  app.cycleFocus(1)
  doAssert app.focus == fpOutlines
  app.cycleFocus(1)
  doAssert app.focus == fpAi
  app.cycleFocus(1)
  doAssert app.focus == fpEditor
  # one-way ring (Shift-Tab only)
  app.focus = fpAi
  app.cfg.filesVisible = false
  app.cfg.outlinesVisible = false
  app.ensureFocusVisible()
  doAssert app.focus == fpAi # still visible
  app.focus = fpFileTree
  app.ensureFocusVisible()
  doAssert app.focus == fpEditor
  doAssert app.focusRing() == @[fpEditor, fpAi]
  app.cycleFocus(1)
  doAssert app.focus == fpAi
  app.cycleFocus(1)
  doAssert app.focus == fpEditor
  echo "testFocusCycle ok"

proc testBinaryLoad() =
  doAssert looksBinary("%PDF-1.4\nstream", "x.pdf")
  doAssert looksBinary("\x00\x01\x02hello", "x.txt")
  doAssert not looksBinary("# hello\nworld\n", "readme.md")
  writeFile("/tmp/tai_bin_test.pdf", "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
  let r = loadFile("/tmp/tai_bin_test.pdf")
  doAssert not r.ok
  doAssert r.refuse
  doAssert r.error.contains("binary")
  echo "testBinaryLoad ok"

when isMainModule:
  testDocument()
  testTabs()
  testWrap()
  testCommands()
  testHighlight()
  testUtf8Clip()
  testOutlinePreview()
  testCacheRag()
  testTools()
  testSseGitTheme()
  testLayoutSmoke()
  testFocusCycle()
  testBinaryLoad()
  echo "all tests passed"
