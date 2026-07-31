# ADR-0005: Multi-theme Tokyo Night family

- Status: Accepted
- Date: 2026-07-31

## Context

Users expect more than one color scheme; Chrome was hard-coded to Tokyo Night.

## Decision

Ship three built-in palettes sharing one `Theme` struct: `tokyo_night`, `catppuccin_mocha`, `gruvbox_dark`. Config key `theme` and `:set theme <id>` call `setTheme`, updating global `Active` used by chrome and syntax.

## Consequences

Custom user themes deferred; only built-ins for v0.4.
