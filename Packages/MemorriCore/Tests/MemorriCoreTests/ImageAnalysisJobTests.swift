import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ImageAnalysisJobTests {
    private struct Rig {
        let fixture: PipelineFixture
        let recogniser: FakeTextRecogniser
        let runner: ImageAnalysisJobRunner
        let ocr: OCRStore
    }

    private func sampleLines() -> [RecognisedLine] {
        [RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
         RecognisedLine(n: 2, text: "Room 4", box: PixelBox(x: 10, y: 50, width: 120, height: 18), confidence: 0.8)]
    }

    private func makeRig(lines: [RecognisedLine]? = nil, failWith error: Error? = nil) throws -> Rig {
        let fixture = try makePipelineFixture()
        let recogniser = FakeTextRecogniser(lines: lines ?? sampleLines(), failWith: error)
        let ocr = OCRStore(database: fixture.database)
        let provider = StoredPictureProvider(paths: fixture.paths, store: fixture.captures)
        let runner = ImageAnalysisJobRunner(pictures: provider, recogniser: recogniser, ocr: ocr, time: FakeTimeSource(1000))
        return Rig(fixture: fixture, recogniser: recogniser, runner: runner, ocr: ocr)
    }

    private func job(_ rig: Rig, kind: String = "analyse", imageID: String? = nil) -> AnalysisJobRecord {
        AnalysisJobRecord(kind: kind, imageId: imageID ?? rig.fixture.imageID, createdAt: Date())
    }

    @Test func anAnalyseJobReadsTheFullResolutionCopyAndStoresItsLines() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.imageSizes.map { [$0.0, $0.1] } == [[1200, 600]])
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID) == sampleLines())
    }

    @Test func aSecondRunDoesNotReadAgain() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(job(rig), attempt: 1)
        let outcome = await rig.runner.run(job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.callCount == 1)
    }

    @Test func aForcedRunReadsAgainAndReplacesTheLines() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(job(rig), attempt: 1)
        let outcome = await rig.runner.run(job(rig, kind: "analyse-force"), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.callCount == 2)
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID).count == 2)
    }

    @Test func aPictureWithNoTextSucceedsWithZeroLines() async throws {
        let rig = try makeRig(lines: []); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(try rig.ocr.isRead(imageID: rig.fixture.imageID))
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID).isEmpty)
    }

    @Test func aMissingPictureIsPermanentAndWritesNothing() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let unknown = await rig.runner.run(job(rig, imageID: "unknown"), attempt: 1)
        let noPicture = await rig.runner.run(AnalysisJobRecord(kind: "analyse", imageId: nil, createdAt: Date()), attempt: 1)
        try rig.fixture.captures.markMissing(imageID: rig.fixture.imageID)
        let marked = await rig.runner.run(job(rig), attempt: 1)
        #expect([unknown, noPicture, marked] == Array(repeating: JobOutcome.permanent("picture no longer stored"), count: 3))
        #expect(rig.recogniser.callCount == 0)
        let reads = try await rig.fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_reads") }
        #expect(reads == 0)
    }

    @Test func aRecogniserErrorIsTransientAndWritesNothing() async throws {
        let rig = try makeRig(failWith: CocoaError(.fileReadUnknown)); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(job(rig), attempt: 1)
        #expect(outcome == .transient("text recognition failed"))
        #expect(try rig.ocr.isRead(imageID: rig.fixture.imageID) == false)
    }
}
