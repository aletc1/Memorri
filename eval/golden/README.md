# Golden set

Fixtures for `memorri-eval`. Each case is a directory:

```
case-name/
  screenshot.png     # input (gitignored if it contains real customer data)
  meta.json          # capture time, display timezone, context hint
  expected.json      # expected appointments, tasks and reminders
```

Use synthetic or redacted screenshots when a case can be shared. Real captures stay local. Only `README.md` and cases under `synthetic/` are tracked.
