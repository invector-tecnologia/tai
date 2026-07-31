## Viewport streaming helpers for large buffers.

type
  Viewport* = object
    scrollY*: int
    scrollX*: int
    height*: int
    width*: int
    margin*: int

proc visibleRange*(v: Viewport, lineCount: int): tuple[startLine, endLine: int] =
  let startLine = max(0, v.scrollY - v.margin)
  let endLine = min(lineCount - 1, v.scrollY + v.height + v.margin)
  (startLine, endLine)

proc clampScroll*(v: var Viewport, lineCount: int) =
  let maxScroll = max(0, lineCount - v.height)
  if v.scrollY < 0: v.scrollY = 0
  if v.scrollY > maxScroll: v.scrollY = maxScroll
