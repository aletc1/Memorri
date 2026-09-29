# 7. Stable local signing identity

- Status: Accepted
- Date: 2026-09-29

## Context and problem
The app is not distributed or notarized. Ad-hoc signatures change on every build, which makes macOS re-ask for Screen Recording permission each time.

## Decision
Sign local builds with a stable self-signed code-signing certificate named Memorri Local, created once in Keychain Access (Certificate Assistant, Code Signing). The app is not sandboxed. Setup steps are documented in the spec 001 quickstart.

## Consequences
One-time manual setup. The app stays unnotarized, so Gatekeeper is bypassed locally with right-click Open.
