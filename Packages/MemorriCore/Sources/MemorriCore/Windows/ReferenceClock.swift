import Foundation

/// The moment that "today", "tomorrow" and weekdays in a window are relative to (spec 011, research R4).
public struct ReferenceClock: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// A clock inside the window's own surroundings (a remote desktop's taskbar).
        case windowClock = "window-clock"
        /// The clock of the screen's menu bar.
        case screenClock = "screen-clock"
        /// No clock was read: the time the picture was captured.
        case capture
        /// A clock was read but is more than a day from the capture time, so it is not trusted.
        case captureFarClock = "capture-far-clock"
    }

    public let instant: Date
    public let source: Source

    public init(instant: Date, source: Source) {
        self.instant = instant; self.source = source
    }

    /// True when the dates that depend on this reference are guesses (a clock was seen and could not be believed).
    public var isGuess: Bool { source == .captureFarClock }
}
