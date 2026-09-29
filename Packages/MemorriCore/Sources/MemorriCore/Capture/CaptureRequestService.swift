import Foundation
import os

public enum CaptureTrigger: String, Sendable {
    case menu
    case shortcut
}

/// A recorded intent to capture. Spec 002 turns it into a real capture.
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
}

/// Single entry point for "capture now", from the menu or the global shortcut.
public actor CaptureRequestService {
    /// A request this soon after the previous accepted one is treated as a double press.
    public static let debounceMilliseconds = 300
    /// How many recent requests are kept in memory.
    public static let historyLimit = 100

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "capture")

    private let permission: PermissionMonitor
    private let feedback: any FeedbackPlaying
    private let settings: CaptureFeedbackSettings
    private let time: any TimeSource
    private let onNeedsOnboarding: @Sendable () -> Void

    private var history: [CaptureRequest] = []
    private var lastAccepted: Date?

    public init(permission: PermissionMonitor,
                feedback: any FeedbackPlaying,
                settings: CaptureFeedbackSettings,
                time: any TimeSource = SystemTimeSource(),
                onNeedsOnboarding: @escaping @Sendable () -> Void) {
        self.permission = permission
        self.feedback = feedback
        self.settings = settings
        self.time = time
        self.onNeedsOnboarding = onNeedsOnboarding
    }

    /// Newest last, at most `historyLimit` items.
    public var recent: [CaptureRequest] { history }

    /// Returns the recorded request, or `nil` when it was dropped as a double press.
    @discardableResult
    public func request(_ trigger: CaptureTrigger) async -> CaptureRequest? {
        let now = time.now()
        if let last = lastAccepted {
            // Rounded to whole milliseconds so 0.3 s apart is exactly on the limit.
            let elapsed = Int((now.timeIntervalSince(last) * 1000).rounded())
            if elapsed < Self.debounceMilliseconds { return nil }
        }
        lastAccepted = now

        let status = await permission.status
        let request = CaptureRequest(timestamp: now, trigger: trigger, permissionAtRequest: status)
        history.append(request)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        Self.logger.notice("capture requested trigger=\(trigger.rawValue, privacy: .public) permission=\(status.rawValue, privacy: .public)")

        if status == .granted {
            if settings.flashIcon { await feedback.flashIcon() }
            if settings.playSound { await feedback.playSound() }
        } else {
            onNeedsOnboarding()
        }
        return request
    }
}
