# ADR-0002: TOML user config

- Status: Accepted
- Date: 2026-07-31

## Context

Users need persistent preferences (file tree side, keymap, AI provider).

## Decision

Store config at `~/.config/tai/config.toml` via `parsetoml`. Secrets may live there or in env (`TAI_API_KEY`, `TAI_BASE_URL`, `TAI_MODEL`).

## Consequences

Config is human-editable; `:set` commands update and rewrite the file.
