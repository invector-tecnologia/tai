## Context menu model for right-click editing and tab actions.

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
    maDuplicate
    maCloseTab
    maNone

  ContextMenu* = object
    visible*: bool
    x*, y*: int
    selected*: int
    items*: seq[tuple[label: string, action: MenuAction]]
    area*: Rect
    targetTab*: int ## -1 = editor menu; otherwise tab index

const
  EditorItems = [
    ("Copy", maCopy),
    ("Cut", maCut),
    ("Paste", maPaste),
    ("Delete", maDelete),
    ("Select All", maSelectAll),
  ]
  TabItems = [
    ("Duplicar", maDuplicate),
    ("Fechar", maCloseTab),
  ]

proc initContextMenu*(): ContextMenu =
  ContextMenu(
    items: @EditorItems,
    targetTab: -1,
  )

proc openEditorMenu*(m: var ContextMenu, x, y: int) =
  m.visible = true
  m.x = x
  m.y = y
  m.selected = 0
  m.targetTab = -1
  m.items = @EditorItems

proc openTabMenu*(m: var ContextMenu, x, y, tabIndex: int) =
  m.visible = true
  m.x = x
  m.y = y
  m.selected = 0
  m.targetTab = tabIndex
  m.items = @TabItems

proc openAt*(m: var ContextMenu, x, y: int) =
  ## Legacy: open editor menu.
  m.openEditorMenu(x, y)

proc close*(m: var ContextMenu) =
  m.visible = false
  m.selected = 0
  m.targetTab = -1

proc actionAt*(m: ContextMenu, row: int): MenuAction =
  if row >= 0 and row < m.items.len:
    m.items[row].action
  else:
    maNone

proc hitTest*(m: ContextMenu, col, row: int): Option[MenuAction] =
  if not m.visible or m.area.isEmpty:
    return none(MenuAction)
  if m.area.contains(col, row):
    # Skip top border row of the block.
    let idx = row - m.area.top - 1
    return some(m.actionAt(idx))
  none(MenuAction)

proc isTabMenu*(m: ContextMenu): bool =
  m.targetTab >= 0
