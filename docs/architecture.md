# Tai Architecture

Tai is a terminal text editor written in **Nim**, built on **[TATUÍ](https://github.com/invector-tecnologia/tatui)**. Version **0.4.0**.

## Five-panel layout

Header (ASCII brand + audio) → tabs → files / editor / outlines → AI bottom.

## Modules

| Path | Role |
|------|------|
| `src/tai/app.nim` | Main loop, layout, vim/helix input |
| `src/tai/config.nim` | TOML config (theme, keymap, MCP, hooks, OAuth) |
| `src/tai/theme.nim` | Tokyo Night / Catppuccin / Gruvbox |
| `src/tai/ai/` | Streaming providers, tools, MCP, skills, hooks, OAuth |
| `src/tai/git/` | `:git` wrappers |
| `src/tai/highlight/` | Regex + tree-sitter auto fallback |
| `src/tai/audio/` | YouTube podcast via mpv |

## AI modes

- **ask** — no tools, streamed answers
- **plan** — read-only tools, numbered plan
- **agent** — write/shell + MCP + skills

## Done (v0.4)

Streaming · plan/ask/agent · `:git` · MCP stdio · skills/hooks · multi-theme · OAuth device-code · Vim modal · tree-sitter auto-fallback

## Still later

MCP HTTP/SSE · native tree-sitter span mapping · GitHub PR · full Vim
