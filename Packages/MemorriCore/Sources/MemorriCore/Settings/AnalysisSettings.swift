import Foundation

/// Whether new captures are analysed without being asked (spec 004, clarification 3). On by default; pausing the
/// queue is a separate switch (spec 003).
public struct AnalysisSettings: Sendable {
    public static let autoKey = "memorri.analysis.auto"

    private let store: any SettingsStore

    public init(store: any SettingsStore) { self.store = store }

    public var automatic: Bool { store.bool(forKey: Self.autoKey, default: true) }

    public func setAutomatic(_ value: Bool) { store.setBool(value, forKey: Self.autoKey) }
}
