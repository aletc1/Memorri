import Foundation

/// What the capture viewer says (spec 007, US2): every line of the capture with the matching words marked, which lines to outline on the picture,
/// and a note when the picture is gone and only the text is left. Pure.
public struct CaptureViewerModel: Sendable, Equatable {
    public let textLines: [LineHit]
    public let pictureStored: Bool

    public init(lines: [RecognisedLine], query: SearchQuery, pictureStored: Bool) {
        let terms = query.terms
        textLines = lines.sorted { $0.n < $1.n }.map { LineHit(number: $0.n, text: MarkedText($0.text, terms: terms)) }
        self.pictureStored = pictureStored
    }

    /// The numbers of the lines that match: the ones to outline on the picture.
    public var matchingNumbers: [Int] { textLines.filter { !$0.text.marks.isEmpty }.map(\.number) }

    public var heading: String {
        switch matchingNumbers.count {
        case 0: "No matching lines"
        case 1: "1 matching line"
        case let n: "\(n) matching lines"
        }
    }

    public var note: String? { pictureStored ? nil : "The capture is no longer stored." }
}
