import Foundation

/// What a notice says (spec 010): `3 new items, 1 needs review`.
public enum NotificationWords {
    public static func text(new: Int, needReview: Int, cancelled: Int) -> String {
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new \(new == 1 ? "item" : "items")") }
        if needReview > 0 { parts.append("\(needReview) \(needReview == 1 ? "needs" : "need") review") }
        if cancelled > 0 { parts.append("\(cancelled) possibly cancelled") }
        return parts.joined(separator: ", ")
    }
}

/// Whether Memorri notifies about new items. On by default; macOS permission is asked at the first notice, never at launch.
public struct NotificationSettings: Sendable {
    public static let enabledKey = "notifications.enabled"

    private let store: any SettingsStore

    public init(store: any SettingsStore) { self.store = store }

    public var enabled: Bool {
        get { store.bool(forKey: Self.enabledKey, default: true) }
        nonmutating set { store.setBool(newValue, forKey: Self.enabledKey) }
    }
}
