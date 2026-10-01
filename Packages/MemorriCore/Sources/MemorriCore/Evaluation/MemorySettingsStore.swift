import Foundation

/// A settings store that lives only as long as the process. `memorri-eval` uses it so a run never reads or
/// changes the app's own settings: every choice comes from the command line.
public final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bools: [String: Bool] = [:]
    private var ints: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var dates: [String: Date] = [:]

    public init() {}

    public func bool(forKey key: String, default defaultValue: Bool) -> Bool { lock.withLock { bools[key] ?? defaultValue } }
    public func setBool(_ value: Bool, forKey key: String) { lock.withLock { bools[key] = value } }
    public func int(forKey key: String) -> Int? { lock.withLock { ints[key] } }
    public func setInt(_ value: Int, forKey key: String) { lock.withLock { ints[key] = value } }
    public func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    public func setString(_ value: String, forKey key: String) { lock.withLock { strings[key] = value } }
    public func date(forKey key: String) -> Date? { lock.withLock { dates[key] } }
    public func setDate(_ value: Date, forKey key: String) { lock.withLock { dates[key] = value } }
}
