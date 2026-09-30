import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct SyntheticCasesTests {
    private let cases = SyntheticCases.all

    private func files(in folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[String(url.resolvingSymlinksInPath().path.dropFirst(root.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private func pixels(_ data: Data) -> (width: Int, height: Int, distinctSamples: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) {
                let p = base + (y * image.width + x) * 4
                seen.insert(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
            }
        }
        return (image.width, image.height, seen.count)
    }

    @Test func thereAreEnoughCasesWithUniqueNames() {
        #expect(cases.count >= 26)
        #expect(Set(cases.map(\.name)).count == cases.count)
    }

    @Test func everyScreenKindAppearsAtLeastTwice() {
        for kind in ScreenKind.allCases {
            #expect(cases.filter { $0.expected.screenKind == kind.rawValue }.count >= 2, "\(kind)")
        }
    }

    @Test func theRequiredSituationsAreCovered() {
        let required = ["relative-date", "header-date", "x-needs-y", "block-30", "block-60", "block-90", "block-120", "text-only-no-end",
                        "midnight-other-zone", "clock-12h", "clock-24h", "lang-en", "lang-es", "remote-frame", "look-outlook",
                        "look-apple-mail", "look-teams", "look-web", "empty-picture", "text-free-picture", "deadline"]
        let present = Set(cases.flatMap(\.features))
        for feature in required { #expect(present.contains(feature), "\(feature)") }
    }

    @Test func featuresAgreeWithTheExpectedAnswers() {
        for c in cases {
            let tags = Dictionary((c.expected.tags ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            #expect(c.features.contains("clock-12h") == (tags["clock_style"] == "12h"), "\(c.name)")
            #expect(c.features.contains("lang-es") == (tags["language"] == "es"), "\(c.name)")
            for f in c.expected.findings where c.features.contains("block-90") && f.title == "Design review" {
                #expect(f.end!.timeIntervalSince(f.start!) == 90 * 60, "\(c.name)")
            }
        }
    }

    @Test func generatingTwiceGivesIdenticalBytes() throws {
        let temp = TempDirectory()
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        try SyntheticCases.generate(into: a)
        try SyntheticCases.generate(into: b)
        let first = try files(in: a), second = try files(in: b)
        #expect(first.count == cases.count * 3)
        #expect(first == second)
    }

    @Test func generatedCasesLoadBackAndDescribeTheirPictures() throws {
        let temp = TempDirectory()
        let out = temp.url.appendingPathComponent("synthetic")
        try SyntheticCases.generate(into: out)
        let loaded = try GoldenCase.loadAll(in: out)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.cases.count == cases.count)
        for c in loaded.cases {
            #expect(c.origin == .synthetic, "\(c.name)")
            let picture = try #require(pixels(try Data(contentsOf: c.pictureURL)), "\(c.name)")
            #expect([picture.width, picture.height] == c.meta.displaySize, "\(c.name)")
            #expect(picture.distinctSamples > 1, "\(c.name) is blank")
            let drawn = c.expected.lines ?? []
            let textFree = c.name.contains("text-free")
            #expect(drawn.isEmpty == (textFree || c.name.contains("empty")), "\(c.name)")
            for line in drawn {
                let box = try #require(line.box, "\(c.name): \(line.text)")
                #expect(box.count == 4 && box[0] >= 0 && box[1] >= 0 && box[0] + box[2] <= picture.width && box[1] + box[3] <= picture.height,
                        "\(c.name): \(line.text) is outside the picture")
            }
        }
    }

    @Test func nothingIsWrittenOutsideTheOutputFolder() throws {
        let temp = TempDirectory()
        let parent = temp.url.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try SyntheticCases.generate(into: parent.appendingPathComponent("out"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["out"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["parent"])
    }

    @Test func findingsAreSelfConsistent() {
        for c in cases {
            for f in c.expected.findings {
                if let start = f.start, let end = f.end { #expect(end > start, "\(c.name): \(f.title)") }
                #expect(["appointment", "task", "reminder", "deadline"].contains(f.kind), "\(c.name): \(f.kind)")
            }
            #expect(c.meta.context == nil || c.expected.context == c.meta.context?.name, "\(c.name)")
        }
    }
}
