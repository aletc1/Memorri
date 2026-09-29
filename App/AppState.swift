import MemorriCore
import Observation

/// What the UI observes: the permission status and whether the icon is flashing.
@MainActor @Observable
final class AppState {
    var permissionStatus: ScreenRecordingStatus = .notGranted
    var isFlashing = false
}
