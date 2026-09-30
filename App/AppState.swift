import Foundation
import MemorriCore
import Observation

/// What the UI observes: the permission status and whether the icon is flashing.
@MainActor @Observable
final class AppState {
    var permissionStatus: ScreenRecordingStatus = .notGranted
    var isFlashing = false
    var isWarning = false

    /// The model queue: counts, pause flag and why it is holding (spec 003).
    var analysis = QueueProgress(counts: JobCounts(waiting: 0, running: 0, finished: 0, failed: 0), paused: false, holdingReason: nil)

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
        case .permissionDenied: break
        }
        now = date
    }

    var lastCaptureLine: String {
        LastCaptureLine.text(for: lastCapture?.result, age: lastCapture.map { now.timeIntervalSince($0.at) } ?? 0)
    }
}
