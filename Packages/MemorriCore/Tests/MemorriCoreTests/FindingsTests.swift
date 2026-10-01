import Foundation
import Testing
@testable import MemorriCore

@Suite struct FindingsTests {
    private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    private func line(_ n: Int, confidence: Double = 0.9) -> RecognisedLine {
        RecognisedLine(n: n, text: "line \(n)", box: PixelBox(x: 0, y: n * 20, width: 100, height: 18), confidence: confidence)
    }

    @Test func aDraftParsesEveryOptionalField() throws {
        let draft = try #require(FindingDraft.parse(json("""
        {"kind":"appointment","title":"Team sync","cited_lines":[3,4],"start_text":"10:00","end_text":"11:30","date_text":"Wed 14",
         "due_text":"Friday","remind_text":"15 min before","all_day":false,"people":["Ana","Ben"],"place":"Room 4","notes":"bring slides",
         "column_line":2,"sent_text":"Tue 13 Oct 09:12","message_time_text":"11:48"}
        """)))
        #expect(draft.kind == .appointment && draft.title == "Team sync" && draft.citedLines == [3, 4])
        #expect(draft.startText == "10:00" && draft.endText == "11:30" && draft.dateText == "Wed 14" && draft.dueText == "Friday")
        #expect(draft.remindText == "15 min before" && draft.allDay == false && draft.people == ["Ana", "Ben"])
        #expect(draft.place == "Room 4" && draft.notes == "bring slides" && draft.columnLine == 2)
        #expect(draft.sentText == "Tue 13 Oct 09:12" && draft.messageTimeText == "11:48")
    }

    @Test func aStartWrittenAsARangeIsSplitIntoStartAndEnd() {
        func split(_ text: String, end: String? = nil) -> (String?, String?) {
            let d = FindingDraft(kind: .appointment, title: "Review", citedLines: [1], startText: text, endText: end).splittingTimeRange()
            return (d.startText, d.endText)
        }
        #expect(split("14:00-15:30") == ("14:00", "15:30"))
        #expect(split("10:00 - 11:00") == ("10:00", "11:00"))
        #expect(split("Thursday, 15 October 2026 14:00–15:00") == ("Thursday, 15 October 2026 14:00", "15:00"))
        #expect(split("9:30am-10:30am") == ("9:30am", "10:30am"))
        #expect(split("14:00-15:30", end: "15:30") == ("14:00-15:30", "15:30"))          // the model already gave an end
        #expect(split("14:00") == ("14:00", nil) && split("2026-10-14") == ("2026-10-14", nil))
        #expect(FindingDraft(kind: .task, title: "T", citedLines: [1]).splittingTimeRange().startText == nil)
    }

    @Test func asAppointmentKeepsEverythingButTheKind() {
        let draft = FindingDraft(kind: .deadline, title: "Standup", citedLines: [4], startText: "10:00", dueText: "10:00", people: ["Ana"], place: "Room 2", columnLine: 3)
        let appointment = draft.asAppointment()
        #expect(appointment.kind == .appointment)
        #expect(appointment == FindingDraft(kind: .appointment, title: "Standup", citedLines: [4], startText: "10:00", dueText: "10:00",
                                            people: ["Ana"], place: "Room 2", columnLine: 3))
    }

    @Test func aDraftWithOnlyTheRequiredFieldsParses() throws {
        let draft = try #require(FindingDraft.parse(json(#"{"kind":"task","title":"Send report","cited_lines":[7]}"#)))
        #expect(draft.startText == nil && draft.allDay == nil && draft.people.isEmpty && draft.place == nil && draft.columnLine == nil)
    }

    @Test func emptyStringsMeanNothingWasRead() throws {
        let draft = try #require(FindingDraft.parse(json(#"{"kind":"task","title":"Send report","cited_lines":[7],"start_text":"","place":" "}"#)))
        #expect(draft.startText == nil && draft.place == nil)
    }

    @Test func aDraftWithAnUnknownKindOrNoCitedLinesIsRejected() {
        #expect(FindingDraft.parse(json(#"{"kind":"meeting","title":"x","cited_lines":[1]}"#)) == nil)
        #expect(FindingDraft.parse(json(#"{"kind":"task","title":"x"}"#)) == nil)
        #expect(FindingDraft.parse(json(#"{"kind":"task","title":"x","cited_lines":"1"}"#)) == nil)
        #expect(FindingDraft.parse(json(#"{"kind":"task","cited_lines":[1]}"#)) == nil)
        #expect(FindingDraft.parse(json(#"{"kind":"task","title":"  ","cited_lines":[1]}"#)) == nil)
    }

    private func draft(_ title: String, cites: [Int]) -> FindingDraft {
        FindingDraft(kind: .task, title: title, citedLines: cites)
    }

    @Test func citationCheckKeepsOnlyDraftsThatCiteExistingLines() {
        let drafts = [draft("ok", cites: [1, 2]), draft("none", cites: []), draft("far", cites: [99]), draft("zero", cites: [0]),
                      draft("mixed", cites: [2, 99]), draft("edge", cites: [5])]
        let result = CitationCheck.apply(drafts, lineCount: 5)
        #expect(result.kept.map(\.title) == ["ok", "edge"])
        #expect(result.discarded.map(\.title) == ["none", "far", "zero", "mixed"])
        #expect(result.discarded[0].reason == "cites no line" && result.discarded[0].citedLines == [])
        #expect(result.discarded[1].reason == "cites a line that does not exist" && result.discarded[1].citedLines == [99])
        #expect(result.discarded[3].citedLines == [2, 99])
    }

    @Test func citationCheckWithNoLinesDiscardsEverything() {
        let result = CitationCheck.apply([draft("a", cites: [1])], lineCount: 0)
        #expect(result.kept.isEmpty && result.discarded.count == 1)
    }

    @Test func citedLinesAreSortedAndDistinct() {
        #expect(CitationCheck.apply([draft("a", cites: [4, 2, 4, 1])], lineCount: 5).kept[0].citedLines == [1, 2, 4])
    }

    @Test func confidenceIsTheLowestCitedLineAndCappedWhenAnythingIsInferred() {
        let lines = [line(1, confidence: 0.95), line(2, confidence: 0.7), line(3, confidence: 0.99)]
        #expect(Finding.confidence(citing: [1, 3], in: lines, anyInferred: false) == 0.95)
        #expect(Finding.confidence(citing: [1, 2, 3], in: lines, anyInferred: false) == 0.7)
        #expect(Finding.confidence(citing: [1, 3], in: lines, anyInferred: true) == 0.5)
        #expect(Finding.confidence(citing: [2], in: lines, anyInferred: true) == 0.5)
        #expect(Finding.confidence(citing: [2], in: [line(2, confidence: 0.3)], anyInferred: true) == 0.3)
        #expect(Finding.confidence(citing: [9], in: lines, anyInferred: false) == 0)
    }

    @Test func onlyDateAndTimeFieldsCarryProvenance() {
        let read = FieldProvenance(origin: .read, rule: "explicit-date", reason: nil)
        let finding = Finding(kind: .appointment, title: "Team sync", allDay: false, timezone: "UTC", people: ["Ana"], place: "Room 4",
                              citedLines: [1], confidence: 0.9,
                              provenance: ["start": read, "end": read, "title": read, "people": read, "place": read, "notes": read, "allDay": read])
        #expect(Set(finding.provenance.keys) == ["start", "end", "allDay"])
        #expect(Finding.provenanceFields == ["start", "end", "due", "remind", "allDay"])
    }

    @Test func aFindingKeepsUnresolvedTextsAndItsKind() {
        let finding = Finding(kind: .deadline, title: "Submit", allDay: true, timezone: "Europe/Madrid", citedLines: [2], confidence: 0.8,
                              unresolved: ["due": "Friday"])
        #expect(finding.due == nil && finding.unresolved == ["due": "Friday"] && finding.kind == .deadline)
        #expect(!finding.id.isEmpty)
    }
}
