# UI contract: Items window (spec 012)

Header, one row, left to right: view switch (List, Calendar; icons) · Show menu (Items, Inbox (N), Approved) · Kind menu · Context menu · dismissed toggle (eye icon) · search field · flexible space · Approve (check), Dismiss (X) or Restore, Merge · Undo (icon).
- Action icons exist only while the selection allows them (same rules as before); each has `.help` text and an accessibility label.
- Undo is always present, dimmed with `Nothing to undo`, else `Undo: <operation>`.
Calendar pane (left): title row (previous, month title, next, Today), weekday row, 5-6 week rows of day cells, then a `No date` strip. Cell: day number (today marked), up to 3 chips (kind symbol, time, title; review dot; dimmed when dismissed), `+N more` opening a popover list. Accessibility: cell `13 October, 3 items`; chip `<kind>, <title>, <time>, needs review`.
Keys: Command-Left/Right previous/next month; Return on a focused chip selects it. Detail pane on the right is unchanged.
