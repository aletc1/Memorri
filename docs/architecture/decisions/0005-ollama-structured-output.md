# 5. Ollama chat API with JSON-schema output

- Status: Accepted
- Date: 2026-09-29

## Context and problem
Extraction results must be machine-readable and reproducible.

## Decision
Call Ollama /api/chat with images, a format JSON schema, temperature near 0 and a configurable think level. Record model name, prompt version, and raw request and response on every extraction run. Spec 003 verifies the model honours the schema with images attached; fall back to schema-in-prompt with validation and repair if not.

## Consequences
Prompt and model changes are auditable and can be re-run (spec 008).
