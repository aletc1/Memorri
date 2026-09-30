import Foundation

/// How long raw captures are kept. Applies to captures only, never to items found in them.
public enum RetentionPolicy: Sendable, Equatable {
    case forever
    case days(Int)

    /// True when this policy keeps captures for less time than `other` (FR-018).
    public func isShorter(than other: RetentionPolicy) -> Bool {
        switch (self, other) {
        case (.days(let mine), .days(let theirs)): mine < theirs
        case (.days, .forever): true
        case (.forever, _): false
        }
    }
}

/// Analysis copy size and retention policy, with the validation rules from the spec
/// (FR-005, FR-017). Out-of-range input is rejected and the previous value kept.
public struct StorageSettings: Sendable {
    public static let modelLongEdgeKey = "memorri.storage.modelLongEdge"
    public static let retentionKey = "memorri.storage.retention"

    public static let modelLongEdgeRange = 512...4096
    public static let defaultModelLongEdge = 2048
    public static let retentionDaysRange = 1...3650
    public static let defaultRetention: RetentionPolicy = .days(7)

    private let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
    }

    public var modelLongEdge: Int {
        guard let value = store.int(forKey: Self.modelLongEdgeKey),
              Self.modelLongEdgeRange.contains(value) else { return Self.defaultModelLongEdge }
        return value
    }

    /// Returns false, leaving the stored value unchanged, when `value` is outside 512 to 4096.
    @discardableResult
    public func setModelLongEdge(_ value: Int) -> Bool {
        guard Self.modelLongEdgeRange.contains(value) else { return false }
        store.setInt(value, forKey: Self.modelLongEdgeKey)
        return true
    }

    public var retention: RetentionPolicy {
        guard let text = store.string(forKey: Self.retentionKey) else { return Self.defaultRetention }
        if text == "forever" { return .forever }
        if let days = Int(text), Self.retentionDaysRange.contains(days) { return .days(days) }
        return Self.defaultRetention
    }

    /// Returns false, leaving the stored value unchanged, when days is outside 1 to 3650.
    @discardableResult
    public func setRetention(_ policy: RetentionPolicy) -> Bool {
        switch policy {
        case .forever:
            store.setString("forever", forKey: Self.retentionKey)
        case .days(let days):
            guard Self.retentionDaysRange.contains(days) else { return false }
            store.setString(String(days), forKey: Self.retentionKey)
        }
        return true
    }
}
