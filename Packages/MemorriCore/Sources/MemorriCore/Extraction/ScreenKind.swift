import Foundation

/// What kind of screen a picture shows; it chooses the instructions and structure for extraction.
public enum ScreenKind: String, Sendable, CaseIterable, Codable {
    case calendarMonth = "calendar_month"
    case calendarWeek = "calendar_week"
    case calendarDay = "calendar_day"
    case email
    case chat
    case document
    case other
}
