import Foundation

/// What the windows call said about one window (spec 011, research R2).
public struct WindowJudgement: Sendable, Equatable {
    public let key: String
    /// False for a window that cannot hold appointments, tasks or reminders.
    public let relevant: Bool
    /// The kind of view, when the window is relevant.
    public let kind: ScreenKind?
    public let confidence: Double
    /// True for a window that shows a remote or virtual desktop: its own taskbar clock is the reference for its dates.
    public let remote: Bool

    public init(key: String, relevant: Bool, kind: ScreenKind?, confidence: Double, remote: Bool) {
        self.key = key; self.relevant = relevant; self.kind = kind; self.confidence = confidence; self.remote = remote
    }
}

/// One stored window of one analysed picture (a `window_readings` row): what the window was, how much of it could be seen, and what the model
/// made of it. Titles are kept here and never logged.
public struct WindowReadingRecord: Sendable, Equatable {
    public let imageID: String
    public let windowKey: String
    public let appName: String?
    public let title: String?
    public let frame: PixelBox
    public let visible: [PixelBox]
    public let visibleShare: Double
    public let relevant: Bool
    public let kind: ScreenKind?
    public let confidence: Double
    public let remote: Bool
    /// The `windows` model run that judged the window; nil when no call was made.
    public let runID: String?
    public let promptVersion: String
    public let createdAt: Date

    public init(imageID: String, windowKey: String, appName: String?, title: String?, frame: PixelBox, visible: [PixelBox], visibleShare: Double,
                relevant: Bool, kind: ScreenKind?, confidence: Double, remote: Bool, runID: String?, promptVersion: String, createdAt: Date) {
        self.imageID = imageID; self.windowKey = windowKey; self.appName = appName; self.title = title; self.frame = frame
        self.visible = visible; self.visibleShare = visibleShare; self.relevant = relevant; self.kind = kind; self.confidence = confidence
        self.remote = remote; self.runID = runID; self.promptVersion = promptVersion; self.createdAt = createdAt
    }

    public var judgement: WindowJudgement {
        WindowJudgement(key: windowKey, relevant: relevant, kind: kind, confidence: confidence, remote: remote)
    }

    func with(imageID: String, runID: String?, createdAt: Date) -> WindowReadingRecord {
        WindowReadingRecord(imageID: imageID, windowKey: windowKey, appName: appName, title: title, frame: frame, visible: visible,
                            visibleShare: visibleShare, relevant: relevant, kind: kind, confidence: confidence, remote: remote,
                            runID: runID ?? self.runID, promptVersion: promptVersion, createdAt: createdAt)
    }
}
