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
- **Bottom:** AI harness + `:` command line (Helix-first, Vim optional)

## Modules

| Path | Role |
|------|------|
| `src/tai/app.nim` | Main loop, layout, events |
| `src/tai/config.nim` | `~/.config/tai/config.toml` |
| `src/tai/buffer/` | Documents + tabs |
| `src/tai/commands/` | Colon commands |
| `src/tai/fs/` | I/O, clipboard, watcher |
| `src/tai/highlight/` | Syntax highlighting |
| `src/tai/preview/` | MD/HTML preview |
| `src/tai/outline/` | Symbol outlines |
| `src/tai/ai/` | Providers, caches, RAG, RTK |

## Epics

1. Infrastructure & architecture
2. Layout, behaviours, commands
3. OS integration & streaming viewport
4. Highlights & content rendering
5. AI harness (caches, RAG, RTK)
