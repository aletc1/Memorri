import Foundation

/// The recogniser sometimes reads the end of one calendar cell and the start of the next as one line (`12:00 | Daily standup`),
/// because the coloured bar in front of an entry is read as a `|` or a `•`. A line that those separators break into parts of at
/// least two characters is split in place, each part keeping its share of the box. A bar at the start (the entry's own) splits nothing.
enum LineSplitter {
    private static let separators: Set<Character> = ["|", "•", "·"]

    static func split(_ lines: [(text: String, box: PixelBox, confidence: Double)]) -> [(text: String, box: PixelBox, confidence: Double)] {
        lines.flatMap(split)
    }

    private static func split(_ line: (text: String, box: PixelBox, confidence: Double)) -> [(text: String, box: PixelBox, confidence: Double)] {
        let characters = Array(line.text)
        var parts: [(range: Range<Int>, text: String)] = []
        var start = 0
        for index in 0...characters.count where index == characters.count || separators.contains(characters[index]) {
            let text = String(characters[start..<index]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { parts.append((start..<index, text)) }
            start = index + 1
        }
        guard parts.count >= 2, parts.allSatisfy({ $0.text.count >= 2 }) else { return [line] }
        let total = max(1, characters.count)
        return parts.map { part in
            let x = line.box.x + line.box.width * part.range.lowerBound / total
            let width = max(1, line.box.width * part.range.count / total)
            return (part.text, PixelBox(x: x, y: line.box.y, width: width, height: line.box.height), line.confidence)
        }
    }
}
