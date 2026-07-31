# ADR-0001: Five-panel layout

- Status: Accepted
- Date: 2026-07-31

## Context

Tai must present files, editor content, outlines, and an AI/command surface simultaneously in a terminal.

## Decision

Use TATUÍ constraint layout with five regions: top (tabs), left, center, right, bottom.
File tree side is configurable; the opposite side shows outlines. Toggle panels with `:hide`/`:show` and items `outlines` or `files` (`arquivos` accepted as alias).

## Consequences

Immediate-mode redraw each tick; panel sizes from `config.toml`. Drawing lives in `app.nim` (no separate panel modules).
