# ADR-0004: AI harness caches, tools, and RTK

- Status: Accepted
- Date: 2026-07-31
- Updated: 2026-07-31

## Context

Agent chat burns tokens on repeated prompts, shell noise, and workspace context. Competitors expect a tool loop, project memory, and interruptible requests.

## Decision

- Prompt cache + context transcript compaction + **exact-match response cache** (JSON on disk)
- Workspace keyword RAG retrieval
- Optional [RTK](https://github.com/rtk-ai/rtk) wrapping of shell output
- Built-in tools (`read_file`, `list_dir`, `grep`, `write_file`, `shell`) with `:agent on` gating writes/shell
- Load `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` into the system prompt
- Background worker thread for HTTP so the TUI keeps polling; Esc requests cancel between tool rounds
- Providers: OpenAI-compatible, Anthropic, Ollama. Auth via API key / env / `:login <token>` (token paste; no OAuth loopback yet)

## Consequences

Honest naming: response cache is not embedding-semantic. Streaming token deltas and MCP remain backlog.
