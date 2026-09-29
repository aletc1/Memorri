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

/// Tracks the permission over time. The launch reading sets the first state; after that only
/// fresh-process reports change it. Transition rules are in `data-model.md`.
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

    /// Records what a freshly started copy of the app reported. A running process keeps the
    /// answer it had at launch and can see neither a grant nor a revocation made afterwards, so
    /// this is the only way to follow the permission after launch.
    ///
    /// - A grant after launch (or after a revocation) means the app must restart.
    /// - A report of "not granted" means the permission is gone, whatever this process still holds.
    @discardableResult
    public func observeFreshProcess(granted: Bool) -> ScreenRecordingStatus {
        switch (status, granted) {
        case (.granted, false): update(to: .notGranted)
        case (.notGranted, true): update(to: .restartRequired)
        case (.restartRequired, false): update(to: .notGranted)
        case (.granted, true), (.notGranted, false), (.restartRequired, true): break
        }
        return status
    }

    private func update(to next: ScreenRecordingStatus) {
        guard next != status else { return }
        status = next
        for continuation in continuations.values { continuation.yield(next) }
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
