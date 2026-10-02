# Core interfaces: window-aware analysis

## Windows (`Packages/MemorriCore/Sources/MemorriCore/Windows/`)

```swift
public struct VisibleWindow: Sendable, Equatable {
    public let key: String                 // "w0", "w1", … or "all"
    public let appName: String?, title: String?, bundleID: String?
    public let frame: PixelBox
    public let visible: [PixelBox]         // frame minus windows in front
    public let visibleShare: Double
    public let lines: [RecognisedLine]     // global line numbers kept
}

public struct VisibleScreen: Sendable, Equatable {
    public let windows: [VisibleWindow]    // front to back, dropped ones removed
    public let desktopLines: [RecognisedLine]
    public static func split(lines: [RecognisedLine], windows: [WindowInfo], pictureWidth: Int, pictureHeight: Int) -> VisibleScreen
}

public struct ReferenceClock: Sendable, Equatable {
    public enum Source: String, Sendable { case windowClock = "window-clock", screenClock = "screen-clock", capture, captureFarClock = "capture-far-clock" }
    public let instant: Date
    public let source: Source
    public var isGuess: Bool { source == .captureFarClock }
    public static func find(window: VisibleWindow?, remote: Bool, screen: VisibleScreen, captureTime: Date, timezone: TimeZone,
                            pictureHeight: Int, locales: [Locale]) -> ReferenceClock
}

public struct WindowJudgement: Sendable, Equatable {   // one entry of the windows call
    public let key: String, relevant: Bool, kind: ScreenKind?, confidence: Double, remote: Bool
}
```

## Pipeline

```swift
public struct PipelineInput { /* adds */ public let reuseWindows: [WindowJudgement]? }
public struct AnalysisResult {
    /* adds */ public let windows: [WindowReadingRecord]     // empty on the old path
    public let reference: ReferenceClock
}
public struct Finding { /* adds */ public let windowKey: String? }
```

`AnalysisPipeline.analyse` takes the per-window path when the capture has a stack with more than one window, else the old path. A failed windows call falls back to the old path.

## Dates

`ResolutionContext` gains `reference: ReferenceClock` (replaces `captureTime` as the "today" of relative dates; `captureTime` stays for logging). `DateHeader.monthAssumed` stays; new `DateHeader.monthConflict`. Provenance reasons: `month-assumed`, `month-conflict`, `reference-assumed`.

## Jobs

```swift
extension ImageAnalysisJobRunner { public static let rereadKind = "reread" }
public struct LibraryReread: Sendable {
    public init(database: StorageDatabase, settings: any SettingsStore, pictures: any FullPictureProviding)
    @discardableResult public func enqueueIfNeeded(now: Date) throws -> Int   // jobs queued; 0 once done
}
```

`AnalysisJobRecord` gains `priority`; `nextRunnable` orders by `priority, created_at, id`.

## Evidence

```swift
extension EvidenceGeometry {
    public static let version = 3
    public static let maxWindowRegion = (width: 1400, height: 800)
    /// The window's frame (clipped to the picture), or a maxWindowRegion rectangle around the cited lines inside it.
    public static func region(lines: [PixelBox], window: PixelBox, pictureWidth: Int, pictureHeight: Int) -> PixelRegion?
}
```

The picture-share rule of version 2 stays for findings without a window.

## Reconciliation and evidence

`SightingRow` and `EvidenceRecord` gain `windowApp: String?`, `windowTitle: String?`. `ItemListModel.windowText(_:)` gives `"<app> — <title>"`, `"<app>"`, or nil.
