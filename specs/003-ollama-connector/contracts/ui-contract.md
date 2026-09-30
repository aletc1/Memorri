# UI Contract: spec 003

What the user sees. Changes to the spec 001 and 002 contracts are marked.

## Menu (changes)

A new disabled line directly under the last-capture line (spec 002), and one new action:

| State | Text |
|---|---|
| nothing queued | `Analysis: idle` |
| jobs waiting, none running | `Analysis: <n> waiting` |
| one running | `Analysing 1 of <n>…` (n = running plus waiting) |
| server or model not usable | `Analysis waiting: Ollama not reachable`, `Analysis waiting: model not installed` or `Analysis waiting: choose a model` |
| paused | `Analysis paused` |

When jobs have failed, `, <k> failed` is added to the line (`Analysis: 2 waiting, 1 failed`, `Analysis: idle, 1 failed`). Precedence when several apply: paused, then waiting for the server or model, then running, then waiting, then idle.

The action below the capture items is **Pause analysis** when not paused and **Resume analysis** when paused. No notifications and no alert windows.

## Settings → Ollama (replaces the placeholder)

Top to bottom, in a scrolling view like Storage:

1. **Connection**: a text field `Server address` (default `http://localhost:11434`) with **Apply**, then a status line and **Check connection**. Status texts: `Reachable, Ollama <version>` · `Not reachable. Start Ollama and try again.` · `No answer within 5 seconds.` · `Ollama is running but no installed model can read images. Install a vision model.` · `Choose a model.` · `The model <name> is not installed.` A rejected address shows `Memorri only talks to Ollama on this Mac. Use localhost, 127.0.0.1 or ::1.` and keeps the previous value. The status is refreshed when the section opens and after Apply.
2. **Model**: a picker `Model` of the vision models, a refresh button, and the note `<n> installed models are hidden because they cannot read images.` (omitted when 0). The recommended model is selected on first use when installed. A warning line `The chosen model <name> is no longer installed.` when it is gone.
3. **Thinking**: a picker `Thinking` with Off, Low, Medium, High. Disabled with the note `This model does not support thinking.` when the model lacks it. When the model only accepts on or off, a note says `This model only supports thinking on or off; Low, Medium and High all mean on.`
4. **Timeout**: a number field `Stop a request after (seconds)`, range 10 to 1800, default 300. Out of range shows `Enter a value between 10 and 1800.` and keeps the previous value. The note `Applies to the next job.` sits under Thinking and Timeout.
5. **Test the model**: a button **Test the model** and a result line: `Answer valid in 12.4 s: "<first 60 characters of the description>"` or `Failed: <reason>`. Uses the newest stored analysis copy, or the built-in sample when there is none, and says which (`Using the newest capture.` or `Using the built-in sample picture.`).
6. **Analysis queue**: counts `Waiting <a> · Running <b> · Finished <c> · Failed <d>`, the last 5 failures as lines `<time> <reason>`, and buttons **Retry failed** and **Clear finished**. **Pause analysis** / **Resume analysis** is repeated here.

## Messages and defaults

- Reasons shown for failed jobs use these texts or a short server message: `timed out`, `connection lost`, `server error <code>`, `invalid answer`, `picture no longer stored`, `request rejected`.
- Defaults until the spike sets them: thinking Off, timeout 300 s.

## Settings keys

`memorri.ollama.address`, `memorri.ollama.model`, `memorri.ollama.think`, `memorri.ollama.timeoutSeconds`, `memorri.analysis.paused` (see the data model).

## Log contract (for the quickstart)

Subsystem `com.aletc1.memorri`, category `ollama`: `check status=<reachable|notReachable|timedOut|noVisionModel|noModelChosen|modelMissing> ms=<n>`, `request model=<name> think=<level> size=<n> attempt=<n> ms=<n> outcome=<success|failed> reason=<text>`. Category `analysis`: `job started id=<uuid> attempt=<n>`, `job finished id=<uuid>`, `job failed id=<uuid> reason=<text>`, `queue holding reason=<text>`, `queue resumed`, `queue paused`, `queue resumed by user`, `recovered running=<n>`.
