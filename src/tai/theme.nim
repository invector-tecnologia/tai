## Tokyo Night color palette for Tai chrome and syntax.

import tatui/core/[color, style]
from std/options import some

type
  Theme* = object
    bg*: Color
    fg*: Color
    comment*: Color
    blue*: Color
    magenta*: Color
    cyan*: Color
    green*: Color
    orange*: Color
    yellow*: Color
    red*: Color
    black*: Color

proc tokyoNight*(): Theme =
  Theme(
    bg: rgb(0x1a, 0x1b, 0x26),
    fg: rgb(0xc0, 0xca, 0xf5),
    comment: rgb(0x56, 0x5f, 0x89),
    blue: rgb(0x7a, 0xa2, 0xf7),
    magenta: rgb(0xbb, 0x9a, 0xf7),
    cyan: rgb(0x7d, 0xcf, 0xff),
    green: rgb(0x9e, 0xce, 0x6a),
    orange: rgb(0xff, 0x9e, 0x64),
    yellow: rgb(0xe0, 0xaf, 0x68),
    red: rgb(0xf7, 0x76, 0x8e),
    black: rgb(0x16, 0x16, 0x1e),
  )

let Tn* = tokyoNight()

proc tnFg*(c: Color, mods: set[Modifier] = {}): Style =
  style(fg = some(c), mods = mods)

proc tnHl*(fg, bg: Color, mods: set[Modifier] = {}): Style =
  style(fg = some(fg), bg = some(bg), mods = mods)
