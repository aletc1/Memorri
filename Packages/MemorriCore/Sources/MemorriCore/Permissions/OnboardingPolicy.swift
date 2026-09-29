/// Decides when the Screen Recording onboarding window opens on its own: only at the very first
/// launch, and only when the permission is missing. A capture requested without the permission
/// opens it separately (see `CaptureRequestService`).
public struct OnboardingPolicy: Sendable {
    public static let completedKey = "memorri.onboarding.completed"

    private let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
    }

    public static func shouldOpenAtLaunch(completed: Bool, status: ScreenRecordingStatus) -> Bool {
        !completed && status != .granted
    }

    /// Call once per launch. Returns whether to open the onboarding window now, and records that
    /// the first launch has happened whatever the permission state was.
    public func decideAtLaunch(status: ScreenRecordingStatus) -> Bool {
        let completed = store.bool(forKey: Self.completedKey, default: false)
        store.setBool(true, forKey: Self.completedKey)
        return Self.shouldOpenAtLaunch(completed: completed, status: status)
    }
}
