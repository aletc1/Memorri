import Foundation

/// State of the Screen Recording permission as the app sees it.
public enum ScreenRecordingStatus: String, Sendable {
    case granted
    case notGranted
    /// The permission was granted while the app was running. macOS only applies it to
    /// processes started afterwards, so the app must relaunch.
    case restartRequired
}

/// Reads whether Screen Recording is currently granted (without capturing anything).
public protocol ScreenRecordingChecking: Sendable {
    func isGranted() -> Bool
}

/// Tracks the permission over time. Transition rules are in `data-model.md`.
public actor PermissionMonitor {
    private let checker: any ScreenRecordingChecking
    public private(set) var status: ScreenRecordingStatus
    private var continuations: [UUID: AsyncStream<ScreenRecordingStatus>.Continuation] = [:]

    /// - Parameter startedGranted: overrides the launch reading; used by tests and previews.
    public init(checker: any ScreenRecordingChecking, startedGranted: Bool? = nil) {
        self.checker = checker
        let granted = startedGranted ?? checker.isGranted()
        self.status = granted ? .granted : .notGranted
    }

    /// Reads the permission again, applies the transition rules and returns the new status.
    @discardableResult
    public func refresh() -> ScreenRecordingStatus {
        let granted = checker.isGranted()
        let next: ScreenRecordingStatus
        switch (status, granted) {
        case (.granted, true): next = .granted
        case (.granted, false): next = .notGranted
        case (.notGranted, true): next = .restartRequired
        case (.notGranted, false): next = .notGranted
        case (.restartRequired, true): next = .restartRequired
        case (.restartRequired, false): next = .notGranted
        }
        if next != status {
            status = next
            for continuation in continuations.values { continuation.yield(next) }
        }
        return status
    }

    /// Emits the current status first, then every change once.
    public func statusUpdates() -> AsyncStream<ScreenRecordingStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ScreenRecordingStatus.self)
        continuation.yield(status)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
