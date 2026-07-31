# Tai

**Editor no terminal. Agente no mesmo lugar.**

Tai is a TUI text editor with an embedded AI coding harness — files, buffer, outline, and agent in one screen. Built in [Nim](https://nim-lang.org) on [TATUÍ](https://github.com/invector-tecnologia/tatui).

```
┌─ TAI EDITOR (ASCII) ── v0.1.0 ── [▶][⏭] podcast ────────┐
│ developed by Bernardo Rosmaninho - www.invector.com.br │
├─ tabs ─────────────────────────────────────────────────┤
│ Files │           editor / preview           │ Outline │
├───────┴──────────────────────────────────────┴─────────┤
│ AI agent  ·  :commands  ·  ask | agent                 │
└────────────────────────────────────────────────────────┘
```

Not another chat-only CLI. You keep editing; the agent lives in the bottom panel and can read (and, when allowed, write) your workspace. Chrome uses a **Tokyo Night** palette.

---

## Why Tai

| | |
|---|---|
| **Editor-first** | Mouse, tabs, syntax highlight, MD/HTML preview — then AI |
| **Helix-style `:`** | Familiar colon commands without leaving the TUI |
| **Honest agent** | Read-only tools by default; `:agent on` unlocks write/shell |
| **Your models** | OpenAI-compatible, Anthropic, or local Ollama |
| **Project memory** | Loads `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` automatically |
| **Tokyo Night** | Branding header + multi-theme (`:set theme`) |
| **Podcast audio** | Play a YouTube video/playlist in the header (`:audio`) |
| **Modes** | `:ask` / `:plan` / `:agent` with streaming replies |
| **Git** | `:git status\|diff\|log\|add\|commit\|branch` |
| **MCP / skills** | Stdio MCP servers + `SKILL.md` + hooks |

---

## Quick start

**Requirements:** Nim ≥ 2.0 · Linux or macOS · optional `xclip`/`wl-clipboard`, `rg`, [rtk](https://github.com/rtk-ai/rtk), [Ollama](https://ollama.com), **mpv** + **yt-dlp** (header podcast player)

```sh
git clone https://github.com/invector-tecnologia/tai.git
cd tai
nimble install -d
nimble build
./tai .
```

Open a file or directory:

```sh
./tai src/tai/app.nim
./tai ~/projects/my-app
```

Set credentials (pick one):

```sh
export TAI_API_KEY="sk-..."
export TAI_BASE_URL="https://api.openai.com/v1"   # optional
export TAI_MODEL="gpt-4o-mini"                    # optional
```

Or inside Tai: `:login <token>` then `:provider openai|anthropic|ollama` and `:model <id>`.

---

## Layout

| Panel | What it does |
|-------|----------------|
| **Header** | ASCII **TAI EDITOR**, credit, version, audio controls |
| **Tabs** | Open buffers; click or `Ctrl-N` / `Ctrl-P` to cycle |
| **Files** | Tree; click or focus + arrows + Enter |
| **Editor** | Edit with mouse and keyboard; right-click menu |
| **Outlines** | Jump to symbols / headings |
| **AI** (bottom) | Transcript + `ai>` prompt or `:` command line |

`Tab` cycles focus: Editor → Files → Outlines → AI → Editor.

Hide sides: `:hide files` · `:hide outlines` (alias `:hide arquivos`).  
Swap file tree: `:set file_tree left|right`.

---

## Editor cheat sheet

| Keys | Action |
|------|--------|
| `:` | Command mode |
| `Ctrl-S` | Save |
| `Ctrl-Z` / `Ctrl-Y` | Undo / redo |
| `Ctrl-C` `X` `V` `A` | Copy / cut / paste / select all |
| `Ctrl-W` | Close tab |
| `Ctrl-N` / `Ctrl-P` | Next / previous tab |
| `Ctrl-Q` | Quit |
| Mouse | Click, drag-select, scroll, right-click menu |

### Colon commands

| Command | |
|---------|--|
| `:w` `:q` `:wq` `:q!` | Write / quit |
| `:e <path>` | Open file |
| `:cd <path>` | Change workspace + refresh tree |
| `:preview` / `:source` | Markdown & HTML preview vs source |
| `:hide` / `:show` `outlines\|files` | Toggle side panels |
| `:set file_tree left\|right` | File tree side |
| `:help` | Short command list |

---

## AI user guide

### Chat

1. `Tab` until the AI panel is focused (or `:ai`).
2. Type a message at `ai>` and press Enter.
3. Selection in the editor is preferred as context; otherwise the open buffer (truncated) is sent.
4. While the agent runs, the title shows `…`. **Esc** requests cancel between tool rounds.
5. `PgUp` / `PgDn` scroll the transcript.

### Modes

| Mode | How | Tools |
|------|-----|--------|
| **Ask** (default) | `:agent off` | `read_file`, `list_dir`, `grep` |
| **Agent** | `:agent on` | + `write_file`, `shell` |

Shell also works via `:shell <command>` when agent mode is on (uses [RTK](https://github.com/rtk-ai/rtk) when installed to shrink noisy output).

### AI commands

| Command | |
|---------|--|
| `:ai` / `:ai <prompt>` | Focus AI or send one-shot prompt |
| `:login <token>` | Save API token (paste; no OAuth yet) |
| `:provider openai\|anthropic\|ollama` | Switch backend |
| `:model <id>` | Switch model mid-session |
| `:agent on\|off` | Allow or block writes/shell |
| `:rag reindex` | Rebuild workspace keyword index |
| `:shell <cmd>` | Run shell (needs `:agent on`) |
| `:clear` | Clear chat + session transcript |

---

## Audio (podcast from YouTube)

Play a YouTube video or playlist in the header like background podcast audio.

**Deps:** `mpv` and `yt-dlp` on `PATH`.

| Command | |
|---------|--|
| `:audio url <link>` | Set playlist/video URL (saved to config) |
| `:audio play` | Start / resume |
| `:audio pause` | Pause |
| `:audio next` | Next item in playlist |
| `:audio stop` | Stop |
| `:audio toggle` | Play ↔ pause |

Click `[▶]` / `[❚❚]` or `[⏭]` in the header. Env: `TAI_AUDIO_URL`.

```toml
[audio]
url = "https://www.youtube.com/playlist?list=..."
autoplay = false
```

### Project memory

On startup (and after `:cd`), Tai loads into the system prompt, if present:

- `AGENTS.md`
- `CLAUDE.md`
- `GEMINI.md`

Put repo conventions there once; every chat picks them up.

### Providers

| Provider | Notes |
|----------|--------|
| **openai** (default) | Any OpenAI-compatible `/v1/chat/completions` endpoint |
| **anthropic** | Messages API |
| **ollama** | Local `http://127.0.0.1:11434/v1` — no cloud key required |

---

## Configuration

File: `~/.config/tai/config.toml`

```toml
file_tree_side = "left"
outlines_visible = true
files_visible = true
preview_mode = false
side_panel_width = 28
bottom_panel_height = 8
workspace = "/home/you/projects/app"

[ai]
provider = "openai"
api_key = ""
base_url = "https://api.openai.com/v1"
model = "gpt-4o-mini"
auth_token = ""

[audio]
url = ""
autoplay = false
```

Prefer env vars for secrets: `TAI_API_KEY`, `TAI_BASE_URL`, `TAI_MODEL`.  
`:login` / `:provider` / `:model` rewrite the TOML (keys may be stored in plaintext).

Session transcript and response cache live under `~/.config/tai/cache/`.

More detail: [docs/architecture.md](docs/architecture.md) · [ADRs](docs/adr/).

---

## Develop

```sh
nimble test    # suite
nimble lint    # nim check
nimble run     # build + run in cwd
```

License: **AGPL-3.0** (aligned with TATUÍ packaging until upstream clarifies MIT vs AGPL).

---

## Roadmap

Shipped in **v0.4.0**: streaming · plan/ask/agent · `:git` · MCP stdio · skills/hooks · multi-theme · OAuth device-code · Vim modal · tree-sitter auto-fallback

Later: MCP HTTP/SSE · native tree-sitter spans · GitHub PR · fuller Vim

---

<p align="center">
  <b>Tai</b> — edit here. Ask here. Ship from the terminal.
  <br/>
  <a href="https://github.com/invector-tecnologia/tai">github.com/invector-tecnologia/tai</a>
</p>
