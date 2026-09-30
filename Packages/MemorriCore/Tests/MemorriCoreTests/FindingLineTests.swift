import Foundation
import Testing
@testable import MemorriCore

@Suite struct FindingLineTests {
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: String) -> Date {
        SyntheticTime.date(y, m, d, h, min, zone: zone)
    }

    @Test func anAppointmentShowsItsStartInThePicturesZone() {
        let finding = Finding(kind: .appointment, title: "Team sync", allDay: false, start: date(2026, 10, 14, 10, 0, zone: "America/New_York"),
                              timezone: "America/New_York", citedLines: [1], confidence: 0.9)
        #expect(FindingLine.text(for: finding) == "Appointment · Team sync · 2026-10-14 10:00")
    }

    @Test func anAllDayFindingShowsOnlyTheDate() {
        let finding = Finding(kind: .deadline, title: "Submit", allDay: true, due: date(2026, 10, 30, zone: "Europe/Madrid"),
                              timezone: "Europe/Madrid", citedLines: [1], confidence: 0.9)
        #expect(FindingLine.text(for: finding) == "Deadline · Submit · 2026-10-30")
    }

    @Test func aTaskShowsItsDueDate() {
        let finding = Finding(kind: .task, title: "Send report", allDay: false, due: date(2026, 10, 16, 17, 0, zone: "UTC"), timezone: "UTC",
                              citedLines: [1], confidence: 0.9)
        #expect(FindingLine.text(for: finding) == "Task · Send report · 2026-10-16 17:00")
    }

    @Test func anInferredEndIsNamedByItsReason() {
        let start = date(2026, 10, 14, 10, 0, zone: "UTC")
        func line(_ reason: String) -> String {
            FindingLine.text(for: Finding(kind: .appointment, title: "Sync", allDay: false, start: start, end: start.addingTimeInterval(3600), timezone: "UTC",
                                          citedLines: [1], confidence: 0.5,
                                          provenance: ["end": FieldProvenance(origin: .inferred, rule: reason, reason: reason)]))
        }
        #expect(line("block-height") == "Appointment · Sync · 2026-10-14 10:00 (inferred end: block height)")
        #expect(line("default-60") == "Appointment · Sync · 2026-10-14 10:00 (inferred end: default 1 h)")
    }

    @Test func anUnresolvedDateShowsTheTextAsWritten() {
        let finding = Finding(kind: .task, title: "Send report", allDay: false, timezone: "UTC", citedLines: [1], confidence: 0.9,
                              unresolved: ["due": "Friday"])
        #expect(FindingLine.text(for: finding) == "Task · Send report · (date unresolved: \"Friday\")")
    }

    @Test func aFindingWithNoDateShowsJustKindAndTitle() {
        let finding = Finding(kind: .reminder, title: "Call Ana", allDay: false, timezone: "UTC", citedLines: [1], confidence: 0.9)
        #expect(FindingLine.text(for: finding) == "Reminder · Call Ana")
    }

    @Test func kindNamesAreReadable() {
        #expect(ScreenKind.calendarWeek.displayName == "Calendar week" && ScreenKind.calendarMonth.displayName == "Calendar month")
        #expect(ScreenKind.calendarDay.displayName == "Calendar day" && ScreenKind.email.displayName == "Email")
        #expect(ScreenKind.chat.displayName == "Chat" && ScreenKind.document.displayName == "Document" && ScreenKind.other.displayName == "Other")
    }
}
