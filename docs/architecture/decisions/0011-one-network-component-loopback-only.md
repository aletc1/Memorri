# 11. One network component, loopback addresses only

- Status: Proposed
- Date: 2026-09-30
- Related: spec 003 (FR-002, FR-019), constitution principle I, ADR 0005

## Context and problem
Spec 003 sends screenshots to Ollama over HTTP. The constitution says captured content never leaves the Mac and that Ollama is reached on localhost only. Until now a source scan forbade all networking code. The feature needs exactly one controlled exception, and the address is a user-editable setting that could be mistyped or pasted with a remote host.

## Options considered
1. Allow networking anywhere and validate the setting in the settings screen: simple, but any future code path could reach a remote host and the rule lives in UI code.
2. Keep forbidding networking and shell out to `curl`: hides the network use from the scan and is harder to test and time out.
3. One component that may use the network, built only from a value type that cannot hold a non-loopback address, with the scan allowing exactly that file.

## Decision
Option 3. `LoopbackAddress` accepts only `http` or `https` URLs whose host is exactly `localhost`, `127.0.0.1` or `::1`, with no user info and no path beyond `/`. `OllamaURLSessionTransport` is the only file allowed to use `URLSession`; it takes a `LoopbackAddress`, re-checks the host of every request and refuses redirects. The no-network test scans core and app sources and allows exactly that one file, and checks that the file enforces the loopback rule. Everything else talks to the `OllamaTransport` protocol, which tests fake.

## Consequences
- A remote Ollama is not supported. If it is ever wanted, it needs a new ADR and an explicit user-facing warning, because it changes the privacy promise.
- Adding another network call anywhere fails the scan until the decision is revisited.
- The app is unsandboxed and has no network entitlement to manage, so the runtime check stays `lsof` in the quickstart.
