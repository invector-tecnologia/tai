## ASCII block banner and credit line for the header.

import std/strutils
import tatui/core/unicodewidth
import ../version

const
  CreditLine* = "developed by Bernardo Rosmaninho - www.invector.com.br"

  ## 5-row box-drawing banner for "TAI EDITOR".
  BannerFull*: array[5, string] = [
    "████████╗ █████╗ ██╗    ███████╗██████╗ ██╗████████╗ ██████╗ ██████╗ ",
    "╚══██╔══╝██╔══██╗██║    ██╔════╝██╔══██╗██║╚══██╔══╝██╔═══██╗██╔══██╗",
    "   ██║   ███████║██║    █████╗  ██║  ██║██║   ██║   ██║   ██║██████╔╝",
    "   ██║   ██╔══██║██║    ██╔════╝██║  ██║██║   ██║   ██║   ██║██╔══██╗",
    "   ██║   ██║  ██║██║    ███████╗██████╔╝██║   ██║   ╚██████╔╝██║  ██║",
  ]

  BannerCompact* = "█ TAI EDITOR █"

proc bannerLines*(width: int): seq[string] =
  ## Prefer the full banner when it fits by *display* columns, not bytes.
  if width >= displayWidth(BannerFull[0]):
    for row in BannerFull:
      result.add row
  else:
    result.add BannerCompact

proc creditWithVersion*(width: int): string =
  let ver = "v" & TaiVersion
  let left = CreditLine
  if width < 20:
    return ver
  if displayWidth(left) + 2 + displayWidth(ver) <= width:
    let pad = width - displayWidth(left) - displayWidth(ver)
    return left & repeat(' ', max(1, pad)) & ver
  ver
