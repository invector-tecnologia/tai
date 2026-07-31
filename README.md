# Tai

**Tai** is a TUI text editor written in [Nim](https://nim-lang.org), using [TATUÍ](https://github.com/invector-tecnologia/tatui) for the terminal UI.

```
┌─────────────────────────── tabs ───────────────────────────┐
│ Files │              editor / preview             │ Outline│
├───────┴───────────────────────────────────────────┴────────┤
│ AI agent + :commands                                       │
└────────────────────────────────────────────────────────────┘
```

## Features

- Five-panel layout (top, left, center, right, bottom)
- Mouse editing: click, select, scroll, right-click context menu
- Multi-file tabs
- File tree + outlines (swap sides with `:set file_tree left|right`)
- Syntax highlighting (Markdown, YAML, TOML, XML, JSON, Shell, Nim, …)
- Source / preview toggle for Markdown & HTML (`:preview` / `:source`)
- Helix-first `:` commands (Vim keymap optional)
- AI panel with API key / web auth, RAG, prompt/context/semantic caches, RTK token filtering

## Requirements

- Nim ≥ 2.0
- Linux or macOS
- Optional: `xclip` or `wl-clipboard`, [`rtk`](https://github.com/rtk-ai/rtk), Ollama for local models

## Build

```sh
nimble install -d
nimble build
./tai [path]
```

## Tests

```sh
nimble test
```

## Config

`~/.config/tai/config.toml` — see [docs/architecture.md](docs/architecture.md).

## License

AGPL-3.0 (inherits TATUÍ packaging license until upstream clarifies MIT vs AGPL).
