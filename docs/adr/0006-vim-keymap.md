# ADR-0006: Vim modal keymap

- Status: Accepted
- Date: 2026-07-31

## Context

Helix-style insert + `:` is the default; Vim users need modal editing.

## Decision

Config `keymap = "helix" | "vim"`. In Vim mode: NORMAL (`hjkl`, `i`/`a`, `dd`/`yy`/`p`, `gg`/`G`, `0`/`$`, `v`, `u`, `:`) and INSERT (Esc returns to NORMAL). Helix mode unchanged (always insert-friendly).

## Consequences

Not a full Vim implementation; subset covering daily editing.
