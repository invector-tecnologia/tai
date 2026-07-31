# ADR-0004: AI harness caches, tools, streaming, MCP

- Status: Accepted
- Date: 2026-07-31
- Updated: 2026-07-31

## Context

Agent chat needs streaming UX, modes, external tools, and optional OAuth.

## Decision

- Modes: **ask** (no tools), **plan** (read-only tools + numbered plan), **agent** (read/write/shell + MCP/skills)
- Token streaming via SSE (`stream: true`) for text-only OpenAI-compat and Anthropic; tool rounds stay buffered then stream final text
- Built-in tools + optional MCP stdio servers + SKILL.md discovery + shell hooks
- Exact-match response cache, keyword RAG, optional RTK
- OAuth device-code when `oauth_client_id` / `device_auth_url` / `token_url` configured; else `:login <token>`

## Consequences

MCP HTTP transport and native tree-sitter spans remain follow-ups.
