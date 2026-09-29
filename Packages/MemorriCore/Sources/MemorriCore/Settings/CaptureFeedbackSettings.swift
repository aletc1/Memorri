/// Whether a capture request flashes the menu-bar icon and plays a sound. Both default to on.
public struct CaptureFeedbackSettings: Sendable {
    public static let flashIconKey = "memorri.feedback.flashIcon"
    public static let playSoundKey = "memorri.feedback.playSound"

    private let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
    }

    public var flashIcon: Bool {
        get { store.bool(forKey: Self.flashIconKey, default: true) }
        nonmutating set { store.setBool(newValue, forKey: Self.flashIconKey) }
    }

    public var playSound: Bool {
        get { store.bool(forKey: Self.playSoundKey, default: true) }
        nonmutating set { store.setBool(newValue, forKey: Self.playSoundKey) }
    }
}
