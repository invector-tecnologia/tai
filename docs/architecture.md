# Tai Architecture

Tai is a terminal text editor written in **Nim**, built on **[TATUÍ](https://github.com/invector-tecnologia/tatui)**.

## Five-panel layout

```
┌──────────────────────── tabs / status ────────────────────────┐
│ Files │              Editor (tabs)               │ Outlines │
│ tree  │          source | preview                 │          │
├───────┴──────────────────────────────────────────┴───────────┤
│ AI chat / :command line                                      │
└──────────────────────────────────────────────────────────────┘
```

- **Top:** navigable editor tabs
- **Left/Right:** file tree (user preference) and outlines (opposite side)
- **Center:** editing surface with mouse, context menu, syntax highlight, preview
- **Bottom:** AI harness + `:` command line (Helix-style)

## Modules

| Path | Role |
|------|------|
| `src/tai/app.nim` | Main loop, layout, events |
| `src/tai/config.nim` | `~/.config/tai/config.toml` |
| `src/tai/buffer/` | Documents + tabs |
| `src/tai/commands/` | Colon commands |
| `src/tai/fs/` | I/O, clipboard, mtime watcher |
| `src/tai/highlight/` | Syntax highlighting |
| `src/tai/preview/` | MD/HTML preview |
| `src/tai/outline/` | Symbol outlines |
| `src/tai/ai/` | Providers, caches, RAG, tools, RTK |

## AI harness (current)

- Providers: OpenAI-compatible, Anthropic, Ollama
- Background HTTP via threads; Esc cancels between tool rounds
- Tools: `read_file`, `list_dir`, `grep`; `write_file` / `shell` require `:agent on`
- Project memory: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`
- Exact-match response cache (JSON), transcript session file, keyword RAG, optional RTK

## Roadmap (backlog)

- MCP client, plan mode, skills/hooks, git commands, tree-sitter highlight, OAuth device-code, theming, Vim modal keymap, true token streaming
