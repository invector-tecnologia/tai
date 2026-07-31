# ADR-0004: AI harness caches and RTK

- Status: Accepted
- Date: 2026-07-31

## Context

Agent chat burns tokens on repeated prompts, shell noise, and workspace context.

## Decision

Layer prompt cache, context transcript compaction, semantic response cache (SQLite/JSON), workspace RAG retrieval, and optional [RTK](https://github.com/rtk-ai/rtk) wrapping of shell tool output.

## Consequences

Works with cloud OpenAI-compatible APIs, Anthropic, Google endpoints, and local Ollama. Auth via API key or web login token paste (`:login`).
