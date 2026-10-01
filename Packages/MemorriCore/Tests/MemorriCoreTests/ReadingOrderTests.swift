import Foundation
import Testing
@testable import MemorriCore

@Suite struct ReadingOrderTests {
    private typealias Item = (text: String, box: PixelBox, confidence: Double)

    private func item(_ text: String, x: Int, y: Int, w: Int = 100, h: Int = 20) -> Item {
        (text, PixelBox(x: x, y: y, width: w, height: h), 0.9)
    }

    @Test func numbersStartAtOneAndFollowRowsThenColumns() {
        let sorted = ReadingOrder.sort([item("d", x: 300, y: 200), item("b", x: 300, y: 100), item("a", x: 0, y: 100), item("c", x: 0, y: 200)])
        #expect(sorted.map(\.text) == ["a", "b", "c", "d"])
        #expect(sorted.map(\.n) == [1, 2, 3, 4])
    }

    @Test func theSameLinesInAnyOrderGiveTheSameNumbers() {
        let items = [item("one", x: 10, y: 10), item("two", x: 200, y: 12), item("three", x: 10, y: 60), item("four", x: 200, y: 58),
                     item("five", x: 10, y: 110), item("six", x: 210, y: 111)]
        let expected = ReadingOrder.sort(items)
        for _ in 0..<20 {
            #expect(ReadingOrder.sort(items.shuffled()) == expected)
        }
    }

    @Test func linesOnOneRowSortLeftToRightEvenWhenTheirTopsDiffer() {
        // Median height 20: a difference of up to 10 px is the same row.
        let sorted = ReadingOrder.sort([item("right", x: 400, y: 100), item("left", x: 10, y: 107), item("middle", x: 200, y: 103)])
        #expect(sorted.map(\.text) == ["left", "middle", "right"])
    }

    @Test func aRowStartsWhenTheTopIsMoreThanHalfAMedianHeightLower() {
        let sorted = ReadingOrder.sort([item("row1-right", x: 400, y: 100), item("row2-left", x: 10, y: 115), item("row1-left", x: 10, y: 100)])
        #expect(sorted.map(\.text) == ["row1-left", "row1-right", "row2-left"])
    }

    @Test func keepsTextBoxAndConfidence() {
        let sorted = ReadingOrder.sort([(text: "x", box: PixelBox(x: 1, y: 2, width: 3, height: 4), confidence: 0.25)])
        #expect(sorted == [RecognisedLine(n: 1, text: "x", box: PixelBox(x: 1, y: 2, width: 3, height: 4), confidence: 0.25)])
    }

    @Test func nothingGivesNothing() {
        #expect(ReadingOrder.sort([]).isEmpty)
    }
}
