# Memorri

A private "second brain" for the macOS menu bar. It reads your screen and turns what it sees into appointments, tasks and reminders.

> **Status: pre-alpha.** The project is bootstrapped (specs, decisions, tooling) but no application code exists yet. Nothing here can be installed or run. See the [roadmap](docs/roadmap.md).

## The problem

If you work through several customer VDIs (remote desktops), each one has its own calendar, mail and tasks, and none of them can sync to your Mac. Your real schedule is scattered across screens you can't connect to your own calendar.

## What Memorri will do

1. **Capture.** Press a global hotkey (or click the menu-bar icon) to screenshot every display.
2. **Understand.** Apple Vision OCR reads the text, and a vision model running locally in [Ollama](https://ollama.com) infers what matters:
   - A calendar in month, week or day view becomes appointments.
   - An email saying "please send me the report" becomes a task: "*Sender* needs *the report*".
   - Text like "action required by Friday" becomes a task with a due date and a reminder.
3. **Complete over time.** Screenshots are often partial. A truncated title or a missing duration is filled in when a later screenshot shows more. The same event seen twice is merged into one item, not duplicated.
4. **Keep evidence.** Every item links to a cropped piece of the screenshot it came from.
5. **Search.** All items and their text are indexed locally for fast in-app search.
6. **Sync (last step).** Confident items are written to a Calendar and a Reminders list you choose, so iCloud carries them to all your devices. Uncertain items wait in an Inbox for your approval.

## Principles

- **Local-first.** Screenshots and inferred data never leave your Mac. Inference runs on localhost only, with no telemetry.
- **You are in control.** Fields you edit are never overwritten. Dismissed items don't come back.
- **Raw data is kept** so decisions can be re-assessed, and you can see its size and clean it up in Settings.

The full list is in the [constitution](.specify/memory/constitution.md).

## Requirements (planned)

- macOS 26 or later
- [Ollama](https://ollama.com) with a vision model (developed against `qwen3.8:27b-mlx`)
- Screen Recording permission, plus Calendar and Reminders access for sync

Memorri is not signed or notarized. It is built and run locally only.

## Roadmap

The app is built one spec at a time, and each spec ends with a runnable increment:

| # | Spec |
|---|---|
| 001 | Menu-bar shell, hotkey and permissions |
| 002 | Capture and local storage |
| 003 | Ollama connector |
| 004 | OCR, extraction and evaluation harness |
| 005 | Reconciliation (no duplicates) |
| 006 | Items UI, evidence and Inbox |
| 007 | Search |
| 008 | Reprocessing |
| 009 | Calendar and Reminders sync |
| 010 | Hardening |

Details and the prompt for each spec are in [`docs/roadmap.md`](docs/roadmap.md).

## Documentation

| | |
|---|---|
| [`DEVELOPER.md`](DEVELOPER.md) | Step-by-step guide to setup, Spec Kit, branches and pull requests |
| [`docs/roadmap.md`](docs/roadmap.md) | Spec order and status |
| [`docs/architecture/decisions/`](docs/architecture/decisions/) | Architecture decision records (ADRs) |
| [`docs/postmortems/`](docs/postmortems/) | Postmortems for incidents and wrong assumptions |
| [`.specify/memory/constitution.md`](.specify/memory/constitution.md) | Project principles |
| [`CLAUDE.md`](CLAUDE.md) | Guidance for the AI coding agent |

## Contributing

Work is spec-driven with [Spec Kit](https://github.com/github/spec-kit) and always goes through a feature branch and a pull request with Conventional Commit titles (`feat:`, `fix:`, `chore:`). Start with [`DEVELOPER.md`](DEVELOPER.md).

## License

[GNU AGPL v3](LICENSE)
