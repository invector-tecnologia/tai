# ADR-0003: Highlight pipeline

- Status: Accepted
- Date: 2026-07-31

## Context

Need multi-language highlighting without blocking the UI on large files.

## Decision

Ship an incremental rule/regex highlighter with a `Highlighter`/`highlightRange` API limited to the visible viewport. Tree-sitter may replace the engine later behind the same interface.

**Update 2026-07-31:** `highlight_engine = auto|regex|treesitter` selects backend. Tree-sitter CLI detection exists; when bindings/HTML mapping are unavailable, auto/treesitter fall back to regex (no crash).

## Consequences

Good enough for Plain, Markdown, YAML, TOML, XML, HTML, JSON, Shell, Nim, Dockerfile, Makefile, env files; not full AST accuracy.
