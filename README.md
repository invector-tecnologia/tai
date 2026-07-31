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
- Multi-file tabs (`Ctrl-N` / `Ctrl-P` to cycle)
- File tree + outlines (swap sides with `:set file_tree left|right`; toggle with `:hide`/`:show outlines|files` — `arquivos` alias kept)
- Keyboard navigation in file tree and outlines when focused (`Tab` cycles focus)
- Syntax highlighting (Markdown, YAML, TOML, XML, JSON, Shell, Nim, …)
- Source / preview toggle for Markdown & HTML (`:preview` / `:source`)
- Helix-style `:` commands
- AI panel: OpenAI-compatible / Anthropic / Ollama, background requests, tool loop (`read_file`, `grep`, `list_dir`; `write_file`/`shell` with `:agent on`), project memory (`AGENTS.md` / `CLAUDE.md`), response cache, workspace RAG, optional [RTK](https://github.com/rtk-ai/rtk)

## Requirements

- Nim ≥ 2.0
- Linux or macOS
- Optional: `xclip` or `wl-clipboard`, `rg`, [`rtk`](https://github.com/rtk-ai/rtk), Ollama for local models

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

Auth: set `TAI_API_KEY` / `ai.api_key`, or `:login <token>` (token paste; OAuth loopback not implemented yet).

## License

AGPL-3.0 (inherits TATUÍ packaging license until upstream clarifies MIT vs AGPL).
