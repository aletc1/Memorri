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
