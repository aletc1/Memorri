import Foundation

extension ScreenKind {
    /// How Settings names the kind of screen.
    public var displayName: String {
        switch self {
        case .calendarMonth: "Calendar month"
        case .calendarWeek: "Calendar week"
        case .calendarDay: "Calendar day"
        case .email: "Email"
        case .chat: "Chat"
        case .document: "Document"
        case .other: "Other"
        }
    }
}

/// The one line Settings shows for a finding: `<kind> · <title> · <start or due in the picture's zone>` with a note when a
/// value was guessed or could not be read as a date.
public enum FindingLine {
    public static func text(for finding: Finding) -> String {
        var parts = [finding.kind.rawValue.capitalized, finding.title]
        let zone = TimeZone(identifier: finding.timezone) ?? .current
        let when = finding.start ?? finding.due ?? finding.remind
        if let when {
            var line = format(when, allDay: finding.allDay, zone: zone)
            if let end = finding.provenance["end"], end.origin == .inferred {
                switch end.reason ?? end.rule {
                case "block-height": line += " (inferred end: block height)"
                case "default-60": line += " (inferred end: default 1 h)"
                default: line += " (inferred end)"
                }
            }
            parts.append(line)
        } else if let text = ["start", "due", "remind"].compactMap({ finding.unresolved[$0] }).first {
            parts.append("(date unresolved: \"\(text)\")")
        }
        return parts.joined(separator: " · ")
    }

    private static func format(_ date: Date, allDay: Bool, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
