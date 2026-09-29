import Foundation

/// Small key-value store for user settings. `UserDefaultsSettingsStore` is the real one;
/// tests use an in-memory fake.
public protocol SettingsStore: Sendable {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool
    func setBool(_ value: Bool, forKey key: String)
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
}
