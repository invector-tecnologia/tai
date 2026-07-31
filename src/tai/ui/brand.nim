## ASCII block banner and credit line for the header.

import std/strutils
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
  if width >= BannerFull[0].len:
    for row in BannerFull:
      result.add row
  else:
    result.add BannerCompact

proc creditWithVersion*(width: int): string =
  let ver = "v" & TaiVersion
  let left = CreditLine
  if width < 20:
    return ver
  if left.len + 2 + ver.len <= width:
    let pad = width - left.len - ver.len
    return left & repeat(' ', max(1, pad)) & ver
  ver
