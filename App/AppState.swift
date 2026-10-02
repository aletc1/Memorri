import Foundation
import MemorriCore
import Observation

/// What the UI observes: the permission status and whether the icon is flashing.
@MainActor @Observable
final class AppState {
    var permissionStatus: ScreenRecordingStatus = .notGranted
    var isFlashing = false
    var isWarning = false

    /// How many items need review (the Inbox), kept current by the item store's observation (spec 006).
    var reviewCount = 0

    /// A request to open the Items window on a scope (the menu's `Inbox`). The id changes with every request so the window notices a repeat.
    struct ScopeRequest: Equatable {
        let id = UUID()
        let scope: ItemScope
        /// An item to select, and its status (a dismissed one needs the dismissed items shown); from a search result.
        var itemID: String?
        var status: ItemStatus?
    }
    var itemsScopeRequest: ScopeRequest?
    /// Whether the search index is built or still being built (spec 007).
    var searchState = SearchState.ready
    /// A capture a search result asked the capture window to show.
    var captureRequest: CaptureRequest?

    /// The model queue: counts, pause flag and why it is holding (spec 003).
    var analysisProgress = QueueProgress(counts: JobCounts(waiting: 0, running: 0, finished: 0, failed: 0), paused: false, holdingReason: nil)

    /// The result shown on the first menu line, and when it happened.
    var lastCapture: (result: LastCaptureResult, at: Date)?
    /// Moves forward every 30 seconds so the relative time on that line stays current.
    var now = Date()

    /// A capture refused for lack of permission shows no line (onboarding opens instead).
    func record(_ outcome: CaptureOutcome, at date: Date = Date()) {
        switch outcome {
        case .complete: lastCapture = (.complete, date)
        case .partial(let captured, let total): lastCapture = (.partial(captured: captured, of: total), date)
        case .failed(let reason): lastCapture = (.failed(reason: reason), date)
        case .windowComplete(let app): lastCapture = (.window(app: app), date)
        case .noWindow(let reason): lastCapture = (.failed(reason: reason.message), date)
        case .permissionDenied: break
        }
        now = date
    }

    var analysisLine: String { AnalysisLine.text(for: analysisProgress) }

    var lastCaptureLine: String {
        LastCaptureLine.text(for: lastCapture?.result, age: lastCapture.map { now.timeIntervalSince($0.at) } ?? 0)
    }
}
