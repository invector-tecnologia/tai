## Multi-palette themes (Tokyo Night, Catppuccin Mocha, Gruvbox Dark).

import tatui/core/[color, style]
from std/options import some
import ./config

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

proc catppuccinMocha*(): Theme =
  Theme(
    bg: rgb(0x1e, 0x1e, 0x2e),
    fg: rgb(0xcd, 0xd6, 0xf4),
    comment: rgb(0x6c, 0x70, 0x86),
    blue: rgb(0x89, 0xb4, 0xfa),
    magenta: rgb(0xcb, 0xa6, 0xf7),
    cyan: rgb(0x94, 0xe2, 0xd5),
    green: rgb(0xa6, 0xe3, 0xa1),
    orange: rgb(0xfa, 0xb3, 0x87),
    yellow: rgb(0xf9, 0xe2, 0xaf),
    red: rgb(0xf3, 0x8b, 0xa8),
    black: rgb(0x11, 0x11, 0x1b),
  )

proc gruvboxDark*(): Theme =
  Theme(
    bg: rgb(0x28, 0x28, 0x28),
    fg: rgb(0xeb, 0xdb, 0xb2),
    comment: rgb(0x92, 0x83, 0x74),
    blue: rgb(0x83, 0xa5, 0x98),
    magenta: rgb(0xd3, 0x86, 0x9b),
    cyan: rgb(0x8e, 0xc0, 0x7c),
    green: rgb(0xb8, 0xbb, 0x26),
    orange: rgb(0xfe, 0x80, 0x19),
    yellow: rgb(0xfa, 0xbd, 0x2f),
    red: rgb(0xfb, 0x49, 0x34),
    black: rgb(0x1d, 0x20, 0x21),
  )

var Active*: Theme = tokyoNight()
var ActiveId*: ThemeId = thTokyoNight

proc setTheme*(id: ThemeId) =
  ActiveId = id
  case id
  of thTokyoNight: Active = tokyoNight()
  of thCatppuccinMocha: Active = catppuccinMocha()
  of thGruvboxDark: Active = gruvboxDark()

# Backward-compatible alias used by existing draw code.
template Tn*: Theme = Active

proc tnFg*(c: Color, mods: set[Modifier] = {}): Style =
  style(fg = some(c), mods = mods)

proc tnHl*(fg, bg: Color, mods: set[Modifier] = {}): Style =
  style(fg = some(fg), bg = some(bg), mods = mods)
