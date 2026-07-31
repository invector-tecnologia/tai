## Panel stubs kept for architecture clarity (drawn from app.nim).

# Top / Left / Center / Right / Bottom panels are composed in `tai/app.nim`
# via TATUÍ constraint layout. This module documents the contract.

const
  PanelTop* = "top"
  PanelLeft* = "left"
  PanelCenter* = "center"
  PanelRight* = "right"
  PanelBottom* = "bottom"
