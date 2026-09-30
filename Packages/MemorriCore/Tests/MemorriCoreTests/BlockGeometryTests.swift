import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct BlockGeometryTests {
    // A week view drawn like the spike's: hour labels down the left, five columns, blocks starting at `hour` and lasting `hours`.
    private struct Block { let column: Int; let hour: Double; let hours: Double; let title: String; let half: Int? }

    private enum Style { case solid, pastel, dark, outlined, rounded }

    private let hourHeight = 80.0, left = 110.0, columnWidth = 300.0, top = 90.0

    private func draw(_ style: Style, labels: [String], blocks: [Block], hourFrom: Int = 9) -> (image: CGImage, lines: [RecognisedLine]) {
        let dark = style == .dark
        let canvas = SyntheticCanvas(width: 1600, height: 1000, background: dark ? RGB(0x1A1A1F) : RGB(0xFFFFFF))
        let ink = dark ? RGB(0xE6E6E6) : RGB(0x000000)
        let grid = dark ? RGB(0x4D4D54) : RGB(0xCCCCCC)
        for (i, label) in labels.enumerated() {
            canvas.text(label, x: 12, y: top + Double(i) * hourHeight - 9, size: 18, color: ink)
            canvas.fill(CGRect(x: left, y: top + Double(i) * hourHeight, width: columnWidth * 5, height: 1), grid)
        }
        let fills: [RGB] = [RGB(0x1F73D9), RGB(0xBF4D33), RGB(0x338C4D), RGB(0x8C4DB3), RGB(0xD98C1A)]
        for (index, block) in blocks.enumerated() {
            var x = left + Double(block.column) * columnWidth + 6
            var width = columnWidth - 12
            if let half = block.half { width = width / 2 - 3; if half == 1 { x += width + 6 } }
            let y = top + block.hour * hourHeight + 2, height = block.hours * hourHeight - 4
            let fill = style == .pastel ? RGB(0xCFE4FA) : style == .dark ? RGB(0x35507A) : fills[index % fills.count]
            let textColor = style == .pastel ? RGB(0x1A1A1A) : RGB(0xFFFFFF)
            switch style {
            case .outlined:
                canvas.stroke(CGRect(x: x, y: y, width: width, height: height), fills[index % fills.count], width: 3)
                canvas.text(block.title, x: x + 12, y: y + 10, size: 20, color: fills[index % fills.count])
            case .rounded:
                canvas.fillRounded(CGRect(x: x, y: y, width: width, height: height), radius: 12, fill)
                canvas.text(block.title, x: x + 12, y: y + 10, size: 20, color: textColor)
            default:
                canvas.fill(CGRect(x: x, y: y, width: width, height: height), fill)
                canvas.text(block.title, x: x + 12, y: y + 10, size: 20, color: textColor)
            }
        }
        let source = CGImageSourceCreateWithData(try! canvas.pngData() as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let lines = canvas.lines.enumerated().map { i, line in
            let b = line.box!
            return RecognisedLine(n: i + 1, text: line.text, box: PixelBox(x: b[0], y: b[1], width: b[2], height: b[3]), confidence: 0.9)
        }
        return (image, lines)
    }

    private let labels24 = (9...17).map { String(format: "%02d:00", $0) }
    private let labelsAmPm = ["9 AM", "10 AM", "11 AM", "12 PM", "1 PM", "2 PM", "3 PM", "4 PM", "5 PM"]
    private let sampleBlocks = [Block(column: 0, hour: 0.5, hours: 0.5, title: "Standup", half: nil), Block(column: 1, hour: 2, hours: 1, title: "Design review", half: nil),
                                Block(column: 2, hour: 4, hours: 1.5, title: "Team sync", half: nil), Block(column: 3, hour: 1, hours: 2, title: "Budget workshop", half: nil)]

    private func titleBox(_ lines: [RecognisedLine], _ title: String) -> PixelBox { lines.first { $0.text == title }!.box }

    // MARK: Hour scale

    @Test func theScaleFitsTwentyFourHourLabels() throws {
        let (_, lines) = draw(.solid, labels: labels24, blocks: [])
        let scale = try #require(BlockGeometry.hourScale(lines: lines))
        #expect(abs(scale.pixelsPerHour - hourHeight) < 0.5)
        #expect(abs(scale.minutes(forPixels: 40) - 30) < 0.5)
    }

    @Test func theScaleFitsAmPmLabels() throws {
        let (_, lines) = draw(.solid, labels: labelsAmPm, blocks: [])
        #expect(abs(try #require(BlockGeometry.hourScale(lines: lines)).pixelsPerHour - hourHeight) < 0.5)
    }

    @Test func fewerThanTwoLabelsGiveNoScale() {
        let (_, lines) = draw(.solid, labels: ["09:00"], blocks: [])
        #expect(BlockGeometry.hourScale(lines: lines) == nil)
        #expect(BlockGeometry.hourScale(lines: []) == nil)
    }

    @Test func labelsThatAreNotInOneNarrowColumnGiveNoScale() {
        func label(_ text: String, x: Int, y: Int) -> RecognisedLine {
            RecognisedLine(n: 1, text: text, box: PixelBox(x: x, y: y, width: 50, height: 18), confidence: 0.9)
        }
        let scattered = [label("09:00", x: 12, y: 90), label("10:00", x: 700, y: 170), label("11:00", x: 1300, y: 250)]
        #expect(BlockGeometry.hourScale(lines: scattered) == nil)
    }

    @Test func labelsThatDoNotGrowWithTheirHoursGiveNoScale() {
        func label(_ text: String, y: Int) -> RecognisedLine { RecognisedLine(n: 1, text: text, box: PixelBox(x: 12, y: y, width: 50, height: 18), confidence: 0.9) }
        #expect(BlockGeometry.hourScale(lines: [label("09:00", y: 90), label("11:00", y: 170), label("10:00", y: 250)]) == nil)
    }

    @Test func blockTextThatLooksLikeATimeAmongOtherTextIsNotAScale() {
        func text(_ t: String, x: Int, y: Int) -> RecognisedLine { RecognisedLine(n: 1, text: t, box: PixelBox(x: x, y: y, width: 100, height: 18), confidence: 0.9) }
        #expect(BlockGeometry.hourScale(lines: [text("Team sync", x: 12, y: 90), text("Room 4", x: 12, y: 170)]) == nil)
    }

    // MARK: Block height and duration

    private func expectMinutes(_ style: Style, labels: [String], exact: Bool = true) throws {
        let blocks = sampleBlocks
        let (image, lines) = draw(style, labels: labels, blocks: blocks)
        for block in blocks {
            let got = BlockGeometry.duration(titleBox: titleBox(lines, block.title), lines: lines, image: image, columnWidth: Int(columnWidth))
            let truth = Int(block.hours * 60)
            if exact { #expect(got == truth, Comment(rawValue: "\(style) \(block.title): \(String(describing: got)) vs \(truth)")) }
            else if let got { #expect(abs(got - truth) <= 15, Comment(rawValue: "\(style) \(block.title): a wrong value \(got) vs \(truth)")) }
        }
    }

    @Test func solidBlocksOf30To120MinutesGiveTheirDuration() throws {
        try expectMinutes(.solid, labels: labels24)
        try expectMinutes(.solid, labels: labelsAmPm)
    }

    @Test func pastelBlocksAlsoWork() throws { try expectMinutes(.pastel, labels: labels24) }

    @Test func darkThemeBlocksWork() throws { try expectMinutes(.dark, labels: labels24) }

    @Test func outlinedAndRoundedBlocksGiveTheRightValueOrNothing() throws {
        try expectMinutes(.outlined, labels: labels24, exact: false)
        try expectMinutes(.rounded, labels: labels24, exact: false)
    }

    @Test func overlappingBlocksShareAColumn() throws {
        let blocks = [Block(column: 4, hour: 2, hours: 1.5, title: "Left talk", half: 0), Block(column: 4, hour: 2.5, hours: 1, title: "Right talk", half: 1)]
        let (image, lines) = draw(.solid, labels: labels24, blocks: blocks)
        #expect(BlockGeometry.duration(titleBox: titleBox(lines, "Left talk"), lines: lines, image: image, columnWidth: Int(columnWidth)) == 90)
        #expect(BlockGeometry.duration(titleBox: titleBox(lines, "Right talk"), lines: lines, image: image, columnWidth: Int(columnWidth)) == 60)
    }

    @Test func aTitleWithNoBlockAroundItGivesNil() {
        let (image, lines) = draw(.solid, labels: labels24, blocks: [])
        let floating = PixelBox(x: 500, y: 300, width: 150, height: 22)
        #expect(BlockGeometry.blockHeight(around: floating, in: image, columnWidth: Int(columnWidth)) == nil)
        #expect(BlockGeometry.duration(titleBox: floating, lines: lines, image: image, columnWidth: Int(columnWidth)) == nil)
    }

    @Test func aRegionWiderThanAColumnIsNotABlock() {
        let banner = Block(column: 0, hour: 1, hours: 1, title: "x", half: nil)
        let canvas = SyntheticCanvas(width: 1600, height: 1000, background: RGB(0xFFFFFF))
        canvas.fill(CGRect(x: 100, y: 200, width: 1400, height: 80), RGB(0x1F73D9))
        let title = canvas.text("Company offsite", x: 300, y: 225, size: 20, color: RGB(0xFFFFFF))
        _ = banner
        let source = CGImageSourceCreateWithData(try! canvas.pngData() as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let box = PixelBox(x: Int(title.minX), y: Int(title.minY), width: Int(title.width), height: Int(title.height))
        #expect(BlockGeometry.blockHeight(around: box, in: image, columnWidth: 300) == nil)
    }

    @Test func noHourLabelsMeansNoDuration() {
        let blocks = [Block(column: 1, hour: 2, hours: 1, title: "Design review", half: nil)]
        let (image, lines) = draw(.solid, labels: [], blocks: blocks)
        #expect(BlockGeometry.duration(titleBox: titleBox(lines, "Design review"), lines: lines, image: image, columnWidth: Int(columnWidth)) == nil)
    }

    @Test func durationsRoundToFifteenMinutesAndAreLimited() {
        #expect(BlockGeometry.roundedMinutes(forPixels: 100, scale: HourScale(pixelsPerHour: 80)) == 75)        // 75.0
        #expect(BlockGeometry.roundedMinutes(forPixels: 41, scale: HourScale(pixelsPerHour: 80)) == 30)         // 30.75 → 30
        #expect(BlockGeometry.roundedMinutes(forPixels: 10, scale: HourScale(pixelsPerHour: 80)) == 30)         // floor of 30
        #expect(BlockGeometry.roundedMinutes(forPixels: 2000, scale: HourScale(pixelsPerHour: 80)) == 720)      // ceiling of 12 h
    }
}
