import Foundation

/// What one window of a capture showed of a week or day calendar, before it is stored: the kind and the stretches of time it showed.
public struct CoverageDraft: Sendable, Equatable {
    public let windowKey: String
    public let kind: ScreenKind
    /// One span per visible day column, in absolute instants (spec 010, research R1).
    public let spans: [DateInterval]

    public init(windowKey: String, kind: ScreenKind, spans: [DateInterval]) { self.windowKey = windowKey; self.kind = kind; self.spans = spans }
}

/// What a stored capture's calendar view covered (`calendar_coverage`). The context is not stored: it is read from the capture when used.
public struct CalendarCoverage: Sendable, Equatable {
    public let imageID: String
    public let windowKey: String
    public let kind: ScreenKind
    public let spans: [DateInterval]

    public init(imageID: String, windowKey: String, kind: ScreenKind, spans: [DateInterval]) {
        self.imageID = imageID; self.windowKey = windowKey; self.kind = kind; self.spans = spans
    }

    /// Whether `moment` lies inside a stretch the view showed.
    public func covers(_ moment: Date) -> Bool { spans.contains { $0.start <= moment && moment <= $0.end } }
}

/// A capture that covered an item's time and did not show it (`cancel_absences`).
public struct CancelAbsence: Sendable, Equatable {
    public let eventID: String
    public let capturedAt: Date

    public init(eventID: String, capturedAt: Date) { self.eventID = eventID; self.capturedAt = capturedAt }
}
