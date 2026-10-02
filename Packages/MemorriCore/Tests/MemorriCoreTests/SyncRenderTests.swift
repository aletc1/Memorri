import Foundation
import Testing
@testable import MemorriCore

/// How an item becomes an entry, and the hash that tells whether it changed (spec 009 FR-005, FR-006).
@Suite struct SyncRenderTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anAppointmentIsAnEventWithItsTimesPlaceAndTheContextInTheTitle() {
        let item = syncItem(title: "Standup", start: start, end: start.addingTimeInterval(1800), place: "Room 4", people: ["Ana", "Luis"])
        let entry = SyncRender.render(SyncSource(item: item, contextName: "Acme", evidence: ["14 Oct 09:12 · Calendar — Week"]))
        #expect(entry.kind == .event && entry.title == "[Acme] Standup" && entry.start == start && entry.end == start.addingTimeInterval(1800))
        #expect(entry.location == "Room 4" && !entry.allDay && entry.due == nil)
        let lines = entry.notes.components(separatedBy: "\n")
        #expect(lines.first == "Made by Memorri" && lines.contains("With: Ana, Luis") && lines.contains("Seen: 14 Oct 09:12 · Calendar — Week"))
        #expect(lines.last == "memorri://item/i1")
    }

    @Test func withoutContextThereIsNoPrefixAndWithoutAnEndATimedEventLastsAnHour() {
        let entry = SyncRender.render(SyncSource(item: syncItem(title: "Standup", start: start)))
        #expect(entry.title == "Standup" && entry.end == start.addingTimeInterval(3600))
        let blank = SyncRender.render(SyncSource(item: syncItem(title: "Standup"), contextName: "  "))
        #expect(blank.title == "Standup")
    }

    @Test func anAllDayEventHasNoEndOfItsOwn() {
        let entry = SyncRender.render(SyncSource(item: syncItem(title: "Holiday", start: start, allDay: true)))
        #expect(entry.allDay && entry.end == nil)
    }

    @Test func aTaskIsAReminderWithItsDueDateAndAReminderItemGetsAnAlarm() {
        let task = SyncRender.render(SyncSource(item: syncItem("t", kind: .task, title: "Pay", start: nil, due: start, place: "Bank")))
        #expect(task.kind == .reminder && task.due == start && task.alarm == nil && task.location == nil)
        #expect(task.notes.contains("Place: Bank"))
        let alarm = SyncRender.render(SyncSource(item: syncItem("r", kind: .reminder, title: "Call", start: nil, due: nil, remind: start)))
        #expect(alarm.kind == .reminder && alarm.alarm == start && alarm.due == nil)
        let deadline = SyncRender.render(SyncSource(item: syncItem("d", kind: .deadline, title: "Report", start: nil, due: start)))
        #expect(deadline.kind == .reminder && deadline.due == start)
    }

    @Test func atMostThreeEvidenceLinesAreWritten() {
        let entry = SyncRender.render(SyncSource(item: syncItem(), evidence: ["a", "b", "c", "d", "e"]))
        #expect(entry.notes.components(separatedBy: "\n").filter { $0.hasPrefix("Seen: ") }.count == 3)
    }

    @Test func theHashIsStableAndChangesWithEveryWrittenField() {
        let base = RenderedEntry(kind: .event, title: "A", start: start, end: start.addingTimeInterval(60), allDay: false, timezone: "UTC", location: "X", due: nil, alarm: nil, notes: "n")
        #expect(SyncRender.hash(base) == SyncRender.hash(base) && SyncRender.hash(base).count == 64)
        var variants: [RenderedEntry] = []
        func vary(_ change: (inout RenderedEntry) -> Void) { var copy = base; change(&copy); variants.append(copy) }
        vary { $0.title = "B" }; vary { $0.start = start.addingTimeInterval(60) }; vary { $0.end = nil }; vary { $0.allDay = true }; vary { $0.location = "Y" }
        vary { $0.due = start }; vary { $0.alarm = start }; vary { $0.notes = "m" }; vary { $0.timezone = "Asia/Tokyo" }
        let hashes = Set(variants.map(SyncRender.hash) + [SyncRender.hash(base)])
        #expect(hashes.count == variants.count + 1)
        // A fraction of a second is not a change: Calendar keeps whole seconds.
        var fractional = base; fractional.start = start.addingTimeInterval(0.3)
        #expect(SyncRender.hash(fractional) == SyncRender.hash(base))
    }

    @Test func changedFieldsNameWhatDiffers() {
        let a = RenderedEntry.sample(.event)
        var b = a; b.title = "Other"; b.notes = "n"; b.end = a.end?.addingTimeInterval(600)
        #expect(SyncRender.changedFields(from: a, to: b) == ["title", "end", "notes"])
        #expect(SyncRender.changedFields(from: a, to: a).isEmpty)
    }

    @Test func outsideEditsAreTheFieldsTheUserChangedWithTheContextPrefixTakenOff() {
        let last = RenderedEntry(kind: .event, title: "[Acme] Standup", start: start, end: start.addingTimeInterval(3600), location: "Room 4", notes: "n")
        var now = last
        now.title = "[Acme] Daily standup"; now.start = start.addingTimeInterval(1800); now.location = ""; now.notes = "something else"
        let edits = SyncRender.outsideEdits(last: last, now: now, contextName: "Acme")
        #expect(edits[.title] == .string("Daily standup") && edits[.start] == .date(start.addingTimeInterval(1800)) && edits[.place] == .null)
        #expect(edits[.end] == nil)                                                   // unchanged
        #expect(edits.count == 3)                                                     // notes are never taken
        var renamed = last; renamed.title = "Daily standup"                           // the user removed the prefix too
        #expect(SyncRender.outsideEdits(last: last, now: renamed, contextName: "Acme")[.title] == .string("Daily standup"))
        #expect(SyncRender.outsideEdits(last: last, now: last, contextName: "Acme").isEmpty)
    }

    @Test func aReminderTakesItsTitleAndDueDateFromTheUser() {
        let last = RenderedEntry(kind: .reminder, title: "Pay", due: start, notes: "n")
        var now = last; now.title = "Pay rent"; now.due = start.addingTimeInterval(86_400); now.alarm = start
        let edits = SyncRender.outsideEdits(last: last, now: now, contextName: nil)
        #expect(edits == [.title: .string("Pay rent"), .due: .date(start.addingTimeInterval(86_400))])
    }
}

/// All-day entries hold calendar days, so they survive a Mac in another time zone unchanged.
@Suite struct SyncRenderDayTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func aDayIsMidnightUTCOfTheDateInTheItemsOwnZoneAndBack() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tokyo
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        let day = SyncRender.day(start, in: tokyo)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.dateComponents([.year, .month, .day, .hour], from: day) == DateComponents(year: 2026, month: 10, day: 14, hour: 0))
        #expect(SyncRender.moment(ofDay: day, in: tokyo) == start)
    }

    @Test func anAllDayItemIsRenderedAsDaysAndASingleDayHasNoEnd() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tokyo
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        var item = syncItem(title: "Holiday", start: start, allDay: true)
        item.timezone = "Asia/Tokyo"
        let one = SyncRender.render(SyncSource(item: item))
        #expect(one.allDay && one.start == SyncRender.day(start, in: tokyo) && one.end == nil)
        item.end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let three = SyncRender.render(SyncSource(item: item))
        #expect(three.end == SyncRender.day(item.end!, in: tokyo))
    }

    @Test func aDayChosenInCalendarComesBackAsTheStartOfThatDayInTheItemsZone() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tokyo
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        let last = RenderedEntry(kind: .event, title: "Holiday", start: SyncRender.day(start, in: tokyo), allDay: true, timezone: "Asia/Tokyo")
        var now = last
        now.start = SyncRender.day(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!, in: tokyo)
        let edits = SyncRender.outsideEdits(last: last, now: now, contextName: nil)
        #expect(edits == [.start: .date(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!)])
    }

    @Test func aReminderDueOnADayIsRenderedAsADay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tokyo
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        var item = syncItem("t", kind: .task, start: nil, due: due, allDay: true)
        item.timezone = "Asia/Tokyo"
        #expect(SyncRender.render(SyncSource(item: item)).due == SyncRender.day(due, in: tokyo))
    }
}
