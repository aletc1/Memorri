# Core Interfaces: MemorriCore

Signatures only; bodies are written test-first during implementation. All types are `Sendable`. Adapters in `App/Adapters/` implement the protocols that touch the system.

```swift
// Capture
public enum CaptureTrigger: String, Sendable { case menu, shortcut }

public struct CaptureRequest: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let trigger: CaptureTrigger
    public let permissionAtRequest: ScreenRecordingStatus
}

public protocol FeedbackPlaying: Sendable {
    func flashIcon() async
    func playSound() async
}

public protocol Clock: Sendable { func now() -> Date }

public actor CaptureRequestService {
    public init(permission: PermissionMonitor, feedback: FeedbackPlaying,
                settings: CaptureFeedbackSettings, clock: Clock,
                onNeedsOnboarding: @escaping @Sendable () -> Void)
    public func request(_ trigger: CaptureTrigger) -> CaptureRequest?   // nil when debounced
    public var recent: [CaptureRequest] { get }                          // newest last, max 100
}

// Permissions
public enum ScreenRecordingStatus: String, Sendable { case granted, notGranted, restartRequired }

public protocol ScreenRecordingChecking: Sendable {
    func isGranted() -> Bool            // CGPreflightScreenCaptureAccess in the adapter
}

public actor PermissionMonitor {
    public init(checker: ScreenRecordingChecking, startedGranted: Bool? = nil)
    public var status: ScreenRecordingStatus { get }
    public func refresh() -> ScreenRecordingStatus   // applies the state machine in data-model.md
    public func statusUpdates() -> AsyncStream<ScreenRecordingStatus>   // yields the current status first, then each change once
}

// Shortcuts
public struct KeyCombo: Hashable, Sendable {
    public enum Modifier: Sendable { case control, option, command, shift }
    public let keyCode: Int
    public let modifiers: Set<Modifier>
}

public enum ShortcutRejection: Equatable, Sendable {
    case noModifier
    case usedByMemorriAction(String)
    case reservedBySystem
}

public protocol SystemShortcutChecking: Sendable {
    func isReservedBySystem(_ combo: KeyCombo) -> Bool
}

public struct ShortcutValidator: Sendable {
    public init(system: SystemShortcutChecking, otherActions: [String: KeyCombo])
    public func validate(_ combo: KeyCombo) -> ShortcutRejection?   // nil means accepted
}

// Lifecycle
public enum SingleInstanceArbiter {
    /// True when another running copy has a lower PID than ownPID. Own PID in otherPIDs is ignored.
    public static func shouldExit(ownPID: Int32, otherPIDs: [Int32]) -> Bool
}

// Onboarding
public enum OnboardingPolicy {
    /// Opens on its own only at the first launch and only when the permission is not granted.
    public static func shouldOpenAtLaunch(completed: Bool, status: ScreenRecordingStatus) -> Bool
}

// Settings
public protocol SettingsStore: Sendable {
    func bool(forKey: String, default: Bool) -> Bool
    func setBool(_ value: Bool, forKey: String)
}

public struct UserDefaultsSettingsStore: SettingsStore {
    public init(defaults: UserDefaults = .standard)
}

public struct CaptureFeedbackSettings: Sendable {
    public init(store: SettingsStore)
    public var flashIcon: Bool { get nonmutating set }
    public var playSound: Bool { get nonmutating set }
}
```

## Behaviour the tests pin down

- `request` returns `nil` and records nothing when called less than 300 ms after the previous accepted request.
- `request` with status other than `granted` records the request, does not call `FeedbackPlaying`, and calls `onNeedsOnboarding` once.
- `request` with `granted` calls `flashIcon` only if `flashIcon` is on and `playSound` only if `playSound` is on.
- `recent` never holds more than 100 items.
- `PermissionMonitor` follows the transition table in `data-model.md` exactly, including revocation while running.
- `ShortcutValidator` applies `noModifier`, then `usedByMemorriAction`, then `reservedBySystem`.
- `SingleInstanceArbiter.shouldExit` is true only when another process has a lower PID.
- `OnboardingPolicy.shouldOpenAtLaunch` is true only when `completed` is false and the status is not `granted`.
