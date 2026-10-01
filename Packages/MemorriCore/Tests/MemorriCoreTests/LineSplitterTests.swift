import Foundation
import Testing
@testable import MemorriCore

@Suite struct LineSplitterTests {
    private func line(_ text: String, x: Int = 100, w: Int = 200) -> (text: String, box: PixelBox, confidence: Double) {
        (text, PixelBox(x: x, y: 50, width: w, height: 14), 0.9)
    }

    @Test func aTimeJoinedToTheNextCellsEntryIsSplit() {
        let parts = LineSplitter.split([line("12:00 | Daily standup", x: 100, w: 220)])
        #expect(parts.map(\.text) == ["12:00", "Daily standup"])
        #expect(parts[0].box.x == 100 && parts[1].box.x > parts[0].box.x + parts[0].box.width - 1 && parts[1].box.x + parts[1].box.width <= 320)
        #expect(parts.allSatisfy { $0.box.y == 50 && $0.box.height == 14 })
    }

    @Test func anEntryWithItsTimeAndThenAnotherEntryIsSplitAtTheBar() {
        #expect(LineSplitter.split([line("Budget review 10:30 • Lunch")]).map(\.text) == ["Budget review 10:30", "Lunch"])
    }

    @Test func aLeadingBarAloneOrAnEntryWithItsOwnTimeIsNotSplit() {
        #expect(LineSplitter.split([line("| Team planning 10:00")]).map(\.text) == ["| Team planning 10:00"])
        #expect(LineSplitter.split([line("Daily standup 12:00")]).map(\.text) == ["Daily standup 12:00"])
    }

    @Test func twoEntriesJoinedAtABarAreSplitToo() {
        #expect(LineSplitter.split([line("Daily standup | Weekly sync")]).map(\.text) == ["Daily standup", "Weekly sync"])
    }

    @Test func aStrayCharacterBesideABarDoesNotSplit() {
        #expect(LineSplitter.split([line("a | Weekly sync")]).map(\.text) == ["a | Weekly sync"])
    }
}
