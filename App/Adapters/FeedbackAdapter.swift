import AppKit
import MemorriCore

/// Confirms a capture request: a brief icon flash and a short system sound.
@MainActor
final class FeedbackAdapter: FeedbackPlaying {
    private let state: AppState
    private static let flashDuration: Duration = .milliseconds(300)

    init(state: AppState) {
        self.state = state
    }

    /// Returns at once; the flash turns itself off after about 300 ms.
    func flashIcon() async {
        state.isFlashing = true
        Task { [state] in
            try? await Task.sleep(for: Self.flashDuration)
            state.isFlashing = false
        }
    }

    func playSound() async {
        NSSound(named: "Pop")?.play()
    }
}
