# Core interfaces: window capture

All in `Packages/MemorriCore/Sources/MemorriCore/`. Signatures show the contract, not the final code.

## Capture

```swift
public enum CaptureScope: String, Sendable { case displays, window }

public struct DesktopRect: Sendable, Equatable, Codable { public let x, y, width, height: Double }   // points, top-left origin

/// One candidate window, front to back as the system lists them.
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let processID: Int32
    public let layer: Int
    public let isOnScreen: Bool
    public let frame: DesktopRect
    public let appName: String?, bundleID: String?, title: String?
}

public enum ActiveWindowChoice: Sendable, Equatable {
    case window(WindowCandidate)
    case none                    // nothing qualifies
    case ownWindow               // Memorri is frontmost
}

public enum ActiveWindowPicker {
    /// Front-most layer-0, on-screen window of the frontmost process; never Memorri's own process (FR-005, FR-007).
    public static func pick(candidates: [WindowCandidate], frontmostProcessID: Int32?, ownProcessID: Int32) -> ActiveWindowChoice
}

public struct WindowCaptureResult: @unchecked Sendable {
    public let image: CGImage                 // native pixels, the screen inside the outline
    public let scale: Double
    public let displayID: UInt32, displayName: String?
    public let frame: DesktopRect             // clipped to the screens
    public let appName: String?, bundleID: String?, title: String?
}

public enum WindowCaptureFailure: Error, Sendable, Equatable {
    case permissionDenied, noWindow, ownWindow, other(String)
}

public protocol WindowCapturing: Sendable {
    func captureActiveWindow() async throws -> WindowCaptureResult      // throws WindowCaptureFailure
}

public protocol CaptureOutlining: Sendable {
    /// Draws the red outline for the frame on each display it touches; returns at once, the outline removes itself.
    func showOutline(for frame: DesktopRect) async
}

/// Pure geometry: per display, the rectangle to stroke, in that display's local top-left coordinates.
public struct OutlineSegment: Sendable, Equatable { public let displayIndex: Int; public let rect: DesktopRect }
public enum CaptureOutlineGeometry {
    public static func segments(for frame: DesktopRect, displays: [DesktopRect]) -> [OutlineSegment]
}
```

## Pipeline and service

```swift
public protocol WindowCaptureRunning: Sendable {
    func runWindow(trigger: CaptureTrigger) async -> CaptureOutcome?     // nil when a capture is already running
}
extension CapturePipeline: WindowCaptureRunning {}                        // run(trigger:) is not changed

extension CaptureOutcome { case windowComplete(app: String?), noWindow(ActiveWindowReason) }   // reason: none | ownWindow

extension CaptureRequestService {
    public func requestWindow(_ trigger: CaptureTrigger)                 // same debounce, history, feedback and permission path
}
```

Rules:
- `runWindow` checks the same free-space floor as `run`, calls `captureActiveWindow`, then stores one event with `scope = window`, one image and one window row (data-model.md), enqueues analysis at the default priority, and then calls `showOutline` once the event is stored. It does not call `showOutline` on any failure.
- The pipeline's `isRunning` guard and the service's single `lastAccepted` timestamp cover both scopes (FR-020).
- `.noWindow` and `.failed` play the existing warning flash and sound; `.permissionDenied` follows the existing onboarding path.
- `LastCaptureLine` shows `Last window capture: <app>, <age>` for `.windowComplete`; the application name is never logged.

## Analysis

```swift
public struct PipelineInput { /* adds */ public let chosenWindow: Bool }   // true when the capture's scope is window

// ReferenceClock.find gains:  windowOnly: Bool
//   true  -> window strip only (when remote), never the screen strip; no clock -> .capture with isGuess == false
//   false -> unchanged (spec 011)
```

Rules:
- With `chosenWindow`, `VisibleScreen.split` returns the one recorded window as the only visible window (key `w0`) with all its lines; `perWindow` is true.
- The windows call runs as in spec 011; every `WindowJudgement.relevant` is replaced with true; `kind` is kept. A failed call falls back to `analyseWhole` as today.
- The window reading is written, so `Reconciler.attach` and `EvidenceWriter` find the application and title.
- `ImageAnalysisJob` fills `chosenWindow` from the event's `scope`; `PipelineCaseAnalyser` fills it from `meta.scope`.
- A capture with `scope = displays` produces the same `PipelineInput` as before (`chosenWindow = false`).

## Storage

```swift
// CaptureEventRecord.scope: CaptureScope = .displays
// CaptureImageRecord.desktopFrame: DesktopRect? = nil
// CaptureStore.insert(event:images:windows:) writes both; reading old rows yields the defaults.
```
