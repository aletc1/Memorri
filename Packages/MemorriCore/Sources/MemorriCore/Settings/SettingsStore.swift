import Foundation

/// Small key-value store for user settings. `UserDefaultsSettingsStore` is the real one;
/// tests use an in-memory fake.
public protocol SettingsStore: Sendable {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool
    func setBool(_ value: Bool, forKey key: String)
    func int(forKey key: String) -> Int?
    func setInt(_ value: Int, forKey key: String)
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func date(forKey key: String) -> Date?
    func setDate(_ value: Date, forKey key: String)
}

/// `SettingsStore` backed by `UserDefaults`.
public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    public func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func int(forKey key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    public func setInt(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setString(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    public func setDate(_ value: Date, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
