import Foundation
import os

public enum CaptureTrigger: String, Sendable {
    case menu
    case shortcut
}

/// What the service hands a request to: the capture pipeline (a fake in tests).
public protocol CaptureRunning: Sendable {
    /// `nil` when another capture is already running.
    func run(trigger: CaptureTrigger) async -> CaptureOutcome?
}

extension CapturePipeline: CaptureRunning {}

/// A recorded intent to capture, kept in memory for diagnostics.
public struct CaptureRequest: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let trigger: CaptureTrigger
    public let permissionAtRequest: ScreenRecordingStatus

    public init(id: UUID = UUID(), timestamp: Date, trigger: CaptureTrigger,
                permissionAtRequest: ScreenRecordingStatus) {
        self.id = id
        self.timestamp = timestamp
        self.trigger = trigger
        self.permissionAtRequest = permissionAtRequest
    }
}

/// Source of the current time (named to avoid clashing with Swift's `Clock`).
public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// Plays the user-visible confirmation for an accepted capture request.
public protocol FeedbackPlaying: Sendable {
    func flashIcon() async
    func playSound() async
    /// Distinct look and sound for a partial or failed capture (FR-006, FR-008, FR-009).
    func flashWarning() async
    func playWarningSound() async
}

/// Single entry point for "capture now", from the menu or the global shortcut.
public actor CaptureRequestService {
    /// A request this soon after the previous accepted one is treated as a double press.
    public static let debounceMilliseconds = 300
    /// How many recent requests are kept in memory.
    public static let historyLimit = 100

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "capture")

    private let runner: any CaptureRunning
    private let permission: PermissionMonitor
    private let feedback: any FeedbackPlaying
    private let settings: CaptureFeedbackSettings
    private let time: any TimeSource
    private let onNeedsOnboarding: @Sendable () -> Void
    private let onOutcome: @Sendable (CaptureOutcome) -> Void

    private var history: [CaptureRequest] = []
    private var lastAccepted: Date?

    public init(runner: any CaptureRunning,
                permission: PermissionMonitor,
                feedback: any FeedbackPlaying,
                settings: CaptureFeedbackSettings,
                time: any TimeSource = SystemTimeSource(),
                onOutcome: @escaping @Sendable (CaptureOutcome) -> Void = { _ in },
                onNeedsOnboarding: @escaping @Sendable () -> Void) {
        self.runner = runner
        self.onOutcome = onOutcome
        self.permission = permission
        self.feedback = feedback
        self.settings = settings
        self.time = time
        self.onNeedsOnboarding = onNeedsOnboarding
    }

    /// Newest last, at most `historyLimit` items.
    public var recent: [CaptureRequest] { history }

    /// Runs one capture and plays the feedback for its outcome. Returns `nil` when the request was
    /// dropped as a double press or ignored because a capture was already running.
    @discardableResult
    public func request(_ trigger: CaptureTrigger) async -> CaptureOutcome? {
        let now = time.now()
        if let last = lastAccepted {
            // Rounded to whole milliseconds so 0.3 s apart is exactly on the limit.
            let elapsed = Int((now.timeIntervalSince(last) * 1000).rounded())
            if elapsed < Self.debounceMilliseconds { return nil }
        }
        lastAccepted = now

        let status = await permission.status
        history.append(CaptureRequest(timestamp: now, trigger: trigger, permissionAtRequest: status))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        Self.logger.notice("capture requested trigger=\(trigger.rawValue, privacy: .public) permission=\(status.rawValue, privacy: .public)")

        // The real capture is the source of truth for the permission, not the tracked status.
        guard let outcome = await runner.run(trigger: trigger) else { return nil }
        onOutcome(outcome)

        switch outcome {
        case .complete:
            await permission.captureSucceeded()
            if settings.flashIcon { await feedback.flashIcon() }
            if settings.playSound { await feedback.playSound() }
        case .partial:
            await permission.captureSucceeded()
            if settings.flashIcon { await feedback.flashWarning() }
            if settings.playSound { await feedback.playWarningSound() }
        case .failed:
            if settings.flashIcon { await feedback.flashWarning() }
            if settings.playSound { await feedback.playWarningSound() }
        case .permissionDenied:
            await permission.captureDeniedByPermission()
            onNeedsOnboarding()
        }
        return outcome
    }
}
