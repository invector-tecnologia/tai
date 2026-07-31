## Context menu model for right-click editing actions.

import std/options
import tatui
import tatui/core/rect

type
  MenuAction* = enum
    maCopy
    maCut
    maPaste
    maDelete
    maSelectAll
    maNone

  ContextMenu* = object
    visible*: bool
    x*, y*: int
    selected*: int
    items*: seq[tuple[label: string, action: MenuAction]]
    area*: Rect

proc initContextMenu*(): ContextMenu =
  ContextMenu(
    items: @[
      ("Copy", maCopy),
      ("Cut", maCut),
      ("Paste", maPaste),
      ("Delete", maDelete),
      ("Select All", maSelectAll),
    ],
  )

proc openAt*(m: var ContextMenu, x, y: int) =
  m.visible = true
  m.x = x
  m.y = y
  m.selected = 0

proc close*(m: var ContextMenu) =
  m.visible = false
  m.selected = 0

proc actionAt*(m: ContextMenu, row: int): MenuAction =
  if row >= 0 and row < m.items.len:
    m.items[row].action
  else:
    maNone

proc hitTest*(m: ContextMenu, col, row: int): Option[MenuAction] =
  if not m.visible or m.area.isEmpty:
    return none(MenuAction)
  if m.area.contains(col, row):
    let idx = row - m.area.top
    return some(m.actionAt(idx))
  none(MenuAction)
