import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct WindowReadingStoreTests {
    private let at = Date(timeIntervalSinceReferenceDate: 7000)

    private func reading(_ imageID: String, key: String, relevant: Bool = true, kind: ScreenKind? = .email, run: String? = "run-1",
                         version: String = "windows-v1") -> WindowReadingRecord {
        WindowReadingRecord(imageID: imageID, windowKey: key, appName: "Mail", title: "Inbox", frame: PixelBox(x: 10, y: 20, width: 800, height: 600),
                            visible: [PixelBox(x: 10, y: 20, width: 500, height: 600)], visibleShare: 0.25, relevant: relevant, kind: kind,
                            confidence: 0.9, remote: false, runID: run, promptVersion: version, createdAt: at)
    }

    @Test func savingReplacesEveryRowOfThePicture() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = WindowReadingStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, readings: [reading(fixture.imageID, key: "w0"), reading(fixture.imageID, key: "w1")])
        try store.save(imageID: fixture.imageID, readings: [reading(fixture.imageID, key: "w3")])
        #expect(try store.readings(imageID: fixture.imageID).map(\.windowKey) == ["w3"])
        try store.save(imageID: fixture.imageID, readings: [])
        #expect(try store.readings(imageID: fixture.imageID).isEmpty)
    }

    @Test func readingsComeBackInKeyOrderWithEveryField() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = WindowReadingStore(database: fixture.database)
        let remote = WindowReadingRecord(imageID: fixture.imageID, windowKey: "w2", appName: nil, title: nil, frame: PixelBox(x: 0, y: 0, width: 5, height: 5),
                                         visible: [], visibleShare: 0.5, relevant: false, kind: nil, confidence: 0.3, remote: true, runID: nil,
                                         promptVersion: "windows-v1", createdAt: at)
        try store.save(imageID: fixture.imageID, readings: [remote, reading(fixture.imageID, key: "w10"), reading(fixture.imageID, key: "w0")])
        let read = try store.readings(imageID: fixture.imageID)
        #expect(read.map(\.windowKey) == ["w0", "w10", "w2"])                 // text order of the keys
        #expect(read[0] == reading(fixture.imageID, key: "w0"))
        #expect(read[2] == remote)
        #expect(read[2].remote && read[2].appName == nil && read[2].kind == nil && read[2].visible.isEmpty)
    }

    @Test func rowsGoWithTheirCaptureImage() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = WindowReadingStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, readings: [reading(fixture.imageID, key: "w0")])
        try fixture.database.pool.write { try $0.execute(sql: "DELETE FROM capture_images WHERE id = ?", arguments: [fixture.imageID]) }
        #expect(try store.readings(imageID: fixture.imageID).isEmpty)
    }

    @Test func thePromptVersionAndTheRunAreKept() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = WindowReadingStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, readings: [reading(fixture.imageID, key: "w0", run: "r-9", version: "windows-v7")])
        let read = try #require(try store.readings(imageID: fixture.imageID).first)
        #expect(read.runID == "r-9" && read.promptVersion == "windows-v7")
    }

    @Test func aJudgementsAreMadeFromAReading() throws {
        let judged = reading("img", key: "w4", relevant: true, kind: .calendarWeek).judgement
        #expect(judged == WindowJudgement(key: "w4", relevant: true, kind: .calendarWeek, confidence: 0.9, remote: false))
    }
}
