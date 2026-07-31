## UTF-8 / display-column helpers for safe TUI clipping.

import std/unicode
import tatui/core/unicodewidth

proc isUtf8Continuation*(c: char): bool {.inline.} =
  (c.uint8 and 0xC0'u8) == 0x80'u8

proc safeRuneLen*(s: string, i: int): int =
  ## Byte length of the rune at `i`, clamped so `i + result <= s.len`.
  if i < 0 or i >= s.len:
    return 0
  result = min(runeLenAt(s, i), s.len - i)
  if result <= 0:
    result = 1

proc floorRuneIndex*(s: string, i: int): int =
  ## Snap a byte index down to the start of a UTF-8 rune.
  if i <= 0:
    return 0
  if i >= s.len:
    return s.len
  result = i
  while result > 0 and s[result].isUtf8Continuation:
    dec result

proc ceilRuneIndex*(s: string, i: int): int =
  ## Snap a byte index up to the next rune start (or len).
  if i <= 0:
    return 0
  if i >= s.len:
    return s.len
  result = i
  while result < s.len and s[result].isUtf8Continuation:
    inc result

proc clipToDisplayWidth*(s: string, maxCols: int): string =
  ## Prefix of `s` that fits in `maxCols` terminal columns (never mid-rune).
  if maxCols <= 0:
    return ""
  var cols = 0
  var i = 0
  while i < s.len:
    let n = safeRuneLen(s, i)
    let w = runeDisplayWidth(s.runeAt(i))
    if w > 0 and cols + w > maxCols:
      break
    result.add s[i ..< i + n]
    cols += w
    i += n

proc sliceBytesSafe*(s: string, startByte, endByte: int): string =
  ## Slice `s[startByte ..< endByte]` snapped to rune boundaries.
  let a = floorRuneIndex(s, startByte)
  let b = floorRuneIndex(s, endByte)
  if b <= a:
    return ""
  s[a ..< b]

proc displayColAtByte*(s: string, byteIdx: int): int =
  ## Display column of the rune starting at `byteIdx` (snapped down).
  let stop = floorRuneIndex(s, byteIdx)
  var i = 0
  while i < stop:
    result += runeDisplayWidth(s.runeAt(i))
    i += safeRuneLen(s, i)

proc byteAtDisplayCol*(s: string, col: int): int =
  ## Byte index of the first rune at display column `col` (or `s.len`).
  if col <= 0:
    return 0
  var c = 0
  var i = 0
  while i < s.len:
    if c >= col:
      return i
    let w = runeDisplayWidth(s.runeAt(i))
    i += safeRuneLen(s, i)
    c += w
  s.len
