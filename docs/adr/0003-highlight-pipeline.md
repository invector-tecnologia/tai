# ADR-0003: Highlight pipeline

- Status: Accepted
- Date: 2026-07-31

## Context

Need multi-language highlighting without blocking the UI on large files.

## Decision

Ship an incremental rule/regex highlighter with a `Highlighter`/`highlightRange` API limited to the visible viewport. Tree-sitter may replace the engine later behind the same interface.

## Consequences

Good enough for Plain, Markdown, YAML, TOML, XML, HTML, JSON, Shell, Nim, Dockerfile, Makefile, env files; not full AST accuracy.
