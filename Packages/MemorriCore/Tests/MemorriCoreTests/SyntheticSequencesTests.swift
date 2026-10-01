import Foundation
import Testing
@testable import MemorriCore

@Suite struct SyntheticSequencesTests {
    @Test func generatingTwiceGivesTheSameBytesAndTheCasesLoadBack() throws {
        let temp = TempDirectory()
        defer { temp.cleanUp() }
        let first = temp.url.appendingPathComponent("a"), second = temp.url.appendingPathComponent("b")
        try SyntheticSequences.generate(into: first)
        try SyntheticSequences.generate(into: second)
        for item in SyntheticSequences.cases {
            let a = try Data(contentsOf: first.appendingPathComponent(item.name).appendingPathComponent("sequence.json"))
            let b = try Data(contentsOf: second.appendingPathComponent(item.name).appendingPathComponent("sequence.json"))
            #expect(a == b)
        }
        let loaded = try SequenceCase.loadAll(in: first)
        #expect(Set(loaded.map(\.name)) == Set(SyntheticSequences.cases.map(\.name)))
        #expect(loaded.count >= 11)
    }

    @Test func theTrackedFolderMatchesTheGenerator() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/golden/synthetic-sequences")
        for item in SyntheticSequences.cases {
            let tracked = try Data(contentsOf: folder.appendingPathComponent(item.name).appendingPathComponent("sequence.json"))
            #expect(tracked == (try item.encoded()), "run memorri-eval generate-sequences: \(item.name) changed")
        }
    }
}
