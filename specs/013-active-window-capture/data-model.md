# Data model: Capture only the active window

One migration (`v13`, see research R9). No table is rebuilt.

## Changes

| Table | Column | Type | Rule |
|---|---|---|---|
| `capture_events` | `scope` | TEXT NOT NULL DEFAULT `'displays'`, CHECK in (`'displays'`, `'window'`) | `displays` for every capture before this feature and every full-screen capture; `window` for a window capture. `trigger` keeps its values (`menu`, `shortcut`). |
| `capture_images` | `desktop_frame_json` | TEXT, nullable | For a window capture, the window's frame on the desktop in points, `{"x":…,"y":…,"width":…,"height":…}` (top-left origin). Null for display pictures. Never logged. |

A window capture holds exactly one `capture_images` row (`display_count` = 1) and one `capture_windows` row for that image: frame `0,0,width,height` of the picture, `stack` 0, the application name, bundle id and title of the window. Everything else (`window_readings`, `findings`, `sightings`, `evidence`, `analysis_jobs`) is written by the existing steps.

## Records

- `CaptureEventRecord` gains `scope: CaptureScope` (`.displays` default, `.window`).
- `CaptureImageRecord` gains `desktopFrame: DesktopRect?`.
- `CaptureScope` is a `String`-backed enum shared by storage, the pipeline input and the eval metadata.

## Lifecycle and removal

- Retention and "Delete everything" remove the event, image and window rows as for any capture; `desktop_frame_json` goes with the image row.
- The window reading written by the analysis is kept with the item while it exists (spec 011, FR-009), including for window captures.

## Existing data

All rows keep `scope = 'displays'` through the default, so nothing changes for captures already stored, and the analysis of a capture whose scope is `displays` takes exactly the path it takes today.
