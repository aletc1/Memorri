import Foundation
@testable import MemorriCore

/// In-memory `SettingsStore` for tests.
final class FakeSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? defaultValue
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func rawValue(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
}

/// Screen Recording checker whose answer the test controls.
final class FakeScreenRecordingChecker: ScreenRecordingChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool

    init(granted: Bool) { self.granted = granted }

    func set(granted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.granted = granted
    }

    func isGranted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return granted
    }
}

/// Time source the test moves by hand.
final class FakeTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ seconds: TimeInterval = 0) { current = Date(timeIntervalSinceReferenceDate: seconds) }

    func set(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = Date(timeIntervalSinceReferenceDate: seconds)
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// Counts feedback calls.
final class FakeFeedback: FeedbackPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var flashes = 0
    private var sounds = 0

    var flashCount: Int { lock.lock(); defer { lock.unlock() }; return flashes }
    var soundCount: Int { lock.lock(); defer { lock.unlock() }; return sounds }

    func flashIcon() async { bump(flash: true) }
    func playSound() async { bump(flash: false) }

    private func bump(flash: Bool) {
        lock.lock(); defer { lock.unlock() }
        if flash { flashes += 1 } else { sounds += 1 }
    }
}

/// Counts how often the onboarding window was requested.
final class OnboardingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
