import CoreGraphics
import Foundation
import Vision

/// One line of text found in a picture, numbered in reading order (1 to count).
public struct RecognisedLine: Sendable, Equatable {
    public let n: Int
    public let text: String
    /// Pixels of the full-resolution picture, top-left origin.
    public let box: PixelBox
    public let confidence: Double

    public init(n: Int, text: String, box: PixelBox, confidence: Double) {
        self.n = n; self.text = text; self.box = box; self.confidence = confidence
    }
}

public protocol TextRecogniser: Sendable {
    /// Reads every line; an empty array is a valid answer.
    func recognise(_ image: CGImage) async throws -> [RecognisedLine]
}

public enum ReadingOrder {
    /// Rows by top edge with half the median line height as tolerance, then left to right. The same lines give the same
    /// numbers whatever order they arrive in.
    public static func sort(_ boxes: [(text: String, box: PixelBox, confidence: Double)]) -> [RecognisedLine] {
        guard !boxes.isEmpty else { return [] }
        let heights = boxes.map(\.box.height).sorted()
        let median = Double(heights[heights.count / 2])
        let tolerance = median / 2

        let byTop = boxes.sorted {
            ($0.box.y, $0.box.x, $0.text, $0.box.width, $0.box.height) < ($1.box.y, $1.box.x, $1.text, $1.box.width, $1.box.height)
        }
        var rows: [[(text: String, box: PixelBox, confidence: Double)]] = []
        var rowTop = 0
        for item in byTop {
            if let last = rows.last, !last.isEmpty, Double(item.box.y - rowTop) <= tolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
                rowTop = item.box.y
            }
        }
        var n = 0
        return rows.flatMap { row in
            row.sorted { ($0.box.x, $0.box.y, $0.text) < ($1.box.x, $1.box.y, $1.text) }.map { item in
                n += 1
                return RecognisedLine(n: n, text: item.text, box: item.box, confidence: item.confidence)
            }
        }
    }
}

enum VisionGeometry {
    /// Vision's boxes are fractions of the picture with the origin at the bottom-left; ours are whole pixels from the top-left.
    /// The box is rounded outward and kept inside the picture.
    static func pixelBox(x: Double, y: Double, width: Double, height: Double, imageWidth: Int, imageHeight: Int) -> PixelBox {
        let w = Double(imageWidth), h = Double(imageHeight)
        let epsilon = 1e-6
        let left = max(0, min(w, ((x * w) + epsilon).rounded(.down)))
        let right = max(left, min(w, ((x + width) * w - epsilon).rounded(.up)))
        let top = max(0, min(h, (((1 - (y + height)) * h) + epsilon).rounded(.down)))
        let bottom = max(top, min(h, ((1 - y) * h - epsilon).rounded(.up)))
        return PixelBox(x: Int(left), y: Int(top), width: max(1, Int(right - left)), height: max(1, Int(bottom - top)))
    }
}

/// Apple Vision text recognition: accurate level, automatic language, language correction as chosen by the spike (S1).
public struct VisionTextRecogniser: TextRecogniser {
    /// Stored in `ocr_reads.recogniser` for the default settings.
    public static let descriptor = "vision-accurate-corrected"

    public let usesLanguageCorrection: Bool

    public init(usesLanguageCorrection: Bool = true) { self.usesLanguageCorrection = usesLanguageCorrection }

    /// The name stored with a read; it changes when the settings of the recogniser change.
    public var descriptor: String { usesLanguageCorrection ? Self.descriptor : "vision-accurate-raw" }

    public func recognise(_ image: CGImage) async throws -> [RecognisedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = true
        let observations = try await ImageRequestHandler(image).perform(request)
        let found = observations.compactMap { observation -> (text: String, box: PixelBox, confidence: Double)? in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let b = observation.boundingBox
            let box = VisionGeometry.pixelBox(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height,
                                              imageWidth: image.width, imageHeight: image.height)
            return (candidate.string, box, Double(candidate.confidence))
        }
        return ReadingOrder.sort(found)
    }
}
