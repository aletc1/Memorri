import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ContextStoreTests {
    private let at = Date(timeIntervalSinceReferenceDate: 7000)

    private func hint(_ kind: ContextHint.Kind, _ value: String) -> ContextHint { ContextHint(kind: kind, value: value) }

    @Test func addStoresNameZoneAndHints() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        let added = try store.add(name: "Customer A", timezone: "America/New_York", hints: [hint(.windowTitle, "Customer A"), hint(.app, "Outlook")])
        #expect(added.name == "Customer A" && added.timezone == "America/New_York" && added.hints.count == 2 && !added.id.isEmpty)
        #expect(try store.all() == [added])
    }

    @Test func aContextMayHaveNoZoneAndNoHints() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        let added = try store.add(name: "Home", timezone: nil, hints: [])
        #expect(added.timezone == nil && added.hints.isEmpty)
    }

    @Test func namesAreTrimmedAndMustBeNew() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        _ = try store.add(name: "  Customer A ", timezone: nil, hints: [])
        #expect(try store.all().first?.name == "Customer A")
        #expect(throws: ContextError.nameInUse) { try store.add(name: "customer a", timezone: nil, hints: []) }
        #expect(throws: ContextError.nameInUse) { try store.add(name: "CUSTOMER A", timezone: nil, hints: []) }
        #expect(throws: ContextError.emptyName) { try store.add(name: "   ", timezone: nil, hints: []) }
        #expect(try store.all().count == 1)
    }

    @Test func anInvalidZoneIsRejected() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        #expect(throws: ContextError.invalidTimezone) { try store.add(name: "X", timezone: "Mars/Olympus", hints: []) }
        #expect(try store.all().isEmpty)
    }

    @Test func aHintShorterThanTwoCharactersIsRejected() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        #expect(throws: ContextError.hintTooShort) { try store.add(name: "X", timezone: nil, hints: [hint(.keyword, "a")]) }
        #expect(throws: ContextError.hintTooShort) { try store.add(name: "X", timezone: nil, hints: [hint(.keyword, "  b ")]) }
        #expect(try store.all().isEmpty)
        let ok = try store.add(name: "X", timezone: nil, hints: [hint(.keyword, " ab ")])
        #expect(ok.hints == [hint(.keyword, "ab")])
    }

    @Test func updateChangesNameZoneAndHints() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        var context = try store.add(name: "Customer A", timezone: "America/New_York", hints: [hint(.app, "Outlook")])
        _ = try store.add(name: "Customer B", timezone: nil, hints: [])
        context.name = "Customer Alpha"
        context.timezone = nil
        context.hints = [hint(.domain, "alpha.example"), hint(.keyword, "Alpha")]
        try store.update(context)
        let back = try #require(try store.all().first { $0.id == context.id })
        #expect(back.name == "Customer Alpha" && back.timezone == nil && back.hints == context.hints)
        context.name = "customer b"
        #expect(throws: ContextError.nameInUse) { try store.update(context) }
        context.name = "CUSTOMER ALPHA"          // the same context may change only the case of its own name
        try store.update(context)
        #expect(try store.all().first { $0.id == context.id }?.name == "CUSTOMER ALPHA")
    }

    @Test func allListsContextsByNameIgnoringCase() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        for name in ["beta", "Alpha", "gamma"] { _ = try store.add(name: name, timezone: nil, hints: []) }
        #expect(try store.all().map(\.name) == ["Alpha", "beta", "gamma"])
    }

    @Test func deletingAContextLeavesPicturesUnassignedAndFindingsIntact() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        let context = try store.add(name: "Customer A", timezone: nil, hints: [hint(.app, "Outlook")])
        let classification = ClassificationResult(kind: .calendarWeek, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: "")
        let finding = Finding(kind: .task, title: "Send", allDay: true, timezone: "UTC", citedLines: [1], confidence: 0.9)
        try AnalysisResultStore(database: fixture.database).save(
            AnalysisResult(lines: [], classification: classification, findings: [finding],
                           decision: ContextDecision(contextID: context.id, source: .auto, score: 5)), imageID: fixture.imageID, runID: nil, at: at)
        try store.delete(id: context.id)
        #expect(try store.all().isEmpty)
        let hints = try fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM context_hints") }
        #expect(hints == 0)
        let decision = try #require(try store.decision(imageID: fixture.imageID))
        #expect(decision.contextID == nil)
        #expect(try AnalysisResultStore(database: fixture.database).findings(imageID: fixture.imageID).count == 1)
    }

    @Test func aUserChoiceIsStoredAndReadBack() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = ContextStore(database: fixture.database)
        #expect(try store.decision(imageID: fixture.imageID) == nil)
        let context = try store.add(name: "Customer A", timezone: nil, hints: [])
        try store.setUserChoice(imageID: fixture.imageID, contextID: context.id, at: at)
        let chosen = try #require(try store.decision(imageID: fixture.imageID))
        #expect(chosen.contextID == context.id && chosen.source == .user && chosen.score == 0)
        // "Unassigned" is also a choice the user can make.
        try store.setUserChoice(imageID: fixture.imageID, contextID: nil, at: at)
        let none = try #require(try store.decision(imageID: fixture.imageID))
        #expect(none.contextID == nil && none.source == .user)
    }
}
