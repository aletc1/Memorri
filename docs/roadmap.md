# Roadmap

Build in order. Each spec ships a runnable, testable increment. Start each session with the prompt below via `/speckit-specify`, then clarify, plan, tasks, analyze, implement.

| # | Spec | Status |
|---|---|---|
| 001 | menubar-shell | Done |
| 002 | capture-and-storage | Not started |
| 003 | ollama-connector | Not started |
| 004 | ocr-extraction-and-eval | Not started |
| 005 | reconciliation | Not started |
| 006 | items-ui-evidence | Not started |
| 007 | search | Not started |
| 008 | reprocessing | Not started |
| 009 | eventkit-sync | Not started |
| 010 | hardening | Not started |

## Prompts

### 001 menubar-shell
Build the Memorri macOS 26+ menu-bar app shell with XcodeGen and a local MemorriCore package. It shows a menu-bar icon with a menu (Capture now, Inbox, Search, Settings, Quit). A configurable global hotkey (default Control+Option+Command+M) triggers Capture, and the menu item is a fallback. A Settings window skeleton exists. Screen Recording permission onboarding shows the current status and links to System Settings. Local builds use a stable self-signed identity so permissions persist (ADR 0007, 0008). Acceptance: the hotkey works while a remote-desktop client is focused and full-screen; permission survives a rebuild.

### 002 capture-and-storage
Capture every display separately with ScreenCaptureKit on hotkey, store full-resolution HEIC images plus a downscaled copy for the model (configurable long edge, default 2048). Create the GRDB database, migrations, and the raw capture_events and capture_images tables. Settings shows storage used, offers cleanup by age or everything, and a retention policy. Excluded from Time Machine.

### 003 ollama-connector
Settings for Ollama URL, vision model picker (from /api/tags with a capability check), think level, timeout and a health check. Include a spike proving qwen3.8:27b-mlx honours a JSON-schema format with images attached, and measure latency at several image sizes. Add a serial background queue with retries and progress shown in the menu (ADR 0005).

### 004 ocr-extraction-and-eval
Run Apple Vision OCR per capture and store lines with boxes. Classify screen type (calendar month/week/day, email, chat, document). Use per-type prompts and a JSON schema; the model cites OCR line IDs. Extract appointments, tasks ("X needs Y") and deadlines with reminders. Resolve relative dates using capture time, context timezone and calendar date headers. Guess missing durations from block height, else 1h, flagged as inferred. Detect the source context (which app, workspace or session a capture came from) automatically with manual override. Deliver the memorri-eval CLI and a golden set with precision, recall and field accuracy, and use it to set the downscale default (ADR 0004).

### 005 reconciliation
Resolve observations into entities without duplicates: candidate retrieval within the same context and time window, scoring on title prefix/truncation, edit distance, embedding similarity (multilingual-e5) and time overlap, with an LLM or reranker for the uncertain band. Progressive merge with per-field observations and provenance, user field locks, aliases, tombstones for dismissed items, and manual merge/split with undo.

### 006 items-ui-evidence
An Items window for Appointments, Tasks and Reminders filtered by context. Detail view shows evidence crops and field provenance. Inline edits lock fields. An Inbox lists low-confidence items for approve or dismiss.

### 007 search
Indexed full-text search (FTS5) over items, aliases and OCR text, with filters by kind, context and date range, and a quick-search panel reachable from the menu.

### 008 reprocessing
Re-run stored captures with a new model or prompt version, compare results against current items, apply selected changes, and keep an audit trail.

### 009 eventkit-sync
Request Calendar and Reminders access, pick a target calendar and a target reminders list, and upsert one-way through sync_links (ADR 0006). Include context in titles, evidence and a deep link in notes, detect edits made in Calendar.app and lock those fields, and offer a dry-run mode. Only confident items sync automatically.

### 010 hardening
Detect cancellations from calendar range coverage (missing items become possibly cancelled and go to the Inbox), notifications for new and review-needed items, launch at login, backup and export, and diagnostic logs.
