# Prompts, schemas and evaluation

## Windows call (`windows-v1`)

Input: the picture at classification size, and per visible window a block:

```
[w1] app: Calendar · title: Calendar · frame: 1725,40 1705x1285 · visible: 100%
  first lines: "Febrero de 2026" | "lun" | "mar" | …
```

Schema (all required):

```json
{ "windows": [ { "key": "w1", "relevant": true, "kind": "calendar_month",
                 "confidence": 0.9, "remote": false, "calendar_name": "" } ],
  "application": "…", "platform_look": "…", "theme": "…",
  "remote_session": { "is_remote": false, "client": "" } }
```

`kind` uses today's `screen_kind` values; `relevant` is false for windows that cannot hold appointments, tasks or reminders. An answer that leaves out a given key, or names an unknown one, is invalid (old path).

## Extraction per window (`extract-<kind>-v13`)

Today's v12 prompt for the kind, with the window's lines only, the window's cut of the picture, and one added rule: "These lines are one window of the screen; cite only these line numbers." Schema unchanged.

## Model runs

Steps `windows` and `extract:<window key>`; the old path keeps `classify` and `extract`.

## Eval

- New synthetic cases (generated, tracked): `windows-calendar-and-mail`, `windows-calendar-under-browser`, `windows-two-calendars-same-event`, `windows-remote-clock-other-zone`, `windows-month-other-month-menu-clock`.
- `meta.json` windows gain `stack`; the golden `expected.json` can name the window of each finding (`window`), scored as a field.
- The report adds `model calls` per case and in total (SC-004).
- Gate: the existing 28 cases keep precision and recall within 0.02 per case (SC-005); new cases at 1.00 on dates.
