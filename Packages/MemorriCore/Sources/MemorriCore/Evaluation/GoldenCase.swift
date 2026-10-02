import Foundation

public enum GoldenOrigin: String, Sendable, Codable { case synthetic, local }

public struct GoldenHint: Sendable, Equatable, Codable {
    public let kind: String
    public let value: String
    public init(kind: String, value: String) { self.kind = kind; self.value = value }
}

public struct GoldenContext: Sendable, Equatable, Codable {
    public let name: String
    public let timezone: String?
    public let hints: [GoldenHint]
    public init(name: String, timezone: String?, hints: [GoldenHint]) { self.name = name; self.timezone = timezone; self.hints = hints }
}

public struct GoldenWindow: Sendable, Equatable, Codable {
    public let app: String?
    public let bundleID: String?
    public let title: String?
    /// x, y, width, height in the picture's pixels.
    public let frame: [Int]
    /// Its place in the stack of windows, 0 for the one in front; nil for a case that does not record one (the window is then one of many with no order).
    public let stack: Int?
    public init(app: String?, bundleID: String?, title: String?, frame: [Int], stack: Int? = nil) {
        self.app = app; self.bundleID = bundleID; self.title = title; self.frame = frame; self.stack = stack
    }
}

public struct GoldenMeta: Sendable, Equatable, Codable {
    public let capturedAt: Date
    public let macTimezone: String
    public let context: GoldenContext?
    public let windows: [GoldenWindow]
    public let displaySize: [Int]
    public let scale: Double
    public let origin: GoldenOrigin?

    public init(capturedAt: Date, macTimezone: String, context: GoldenContext?, windows: [GoldenWindow],
                displaySize: [Int], scale: Double, origin: GoldenOrigin?) {
        self.capturedAt = capturedAt; self.macTimezone = macTimezone; self.context = context; self.windows = windows
        self.displaySize = displaySize; self.scale = scale; self.origin = origin
    }

    enum CodingKeys: String, CodingKey { case capturedAt, macTimezone, context, windows, displaySize, scale, origin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        macTimezone = try c.decode(String.self, forKey: .macTimezone)
        context = try c.decodeIfPresent(GoldenContext.self, forKey: .context)
        windows = try c.decodeIfPresent([GoldenWindow].self, forKey: .windows) ?? []
        displaySize = try c.decode([Int].self, forKey: .displaySize)
        scale = try c.decode(Double.self, forKey: .scale)
        origin = try c.decodeIfPresent(GoldenOrigin.self, forKey: .origin)
    }
}

public struct ExpectedTag: Sendable, Equatable, Codable {
    public let key: String
    public let value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct ExpectedLine: Sendable, Equatable, Codable {
    public let text: String
    /// x, y, width, height in the picture's pixels (synthetic cases know where they drew it).
    public let box: [Int]?
    public init(text: String, box: [Int]?) { self.text = text; self.box = box }
}

public struct ExpectedFinding: Sendable, Equatable, Codable {
    public let kind: String
    public let title: String
    public let start: Date?
    public let end: Date?
    public let due: Date?
    public let remind: Date?
    public let allDay: Bool?
    public let people: [String]?
    public let place: String?
    /// Fields the pipeline should flag as inferred (`end`, `remind`, ...).
    public let inferred: [String]?
    /// The key of the window it is shown in (`w<stack>`), when the case has several; scored as a field.
    public let window: String?

    public init(kind: String, title: String, start: Date? = nil, end: Date? = nil, due: Date? = nil, remind: Date? = nil,
                allDay: Bool? = nil, people: [String]? = nil, place: String? = nil, inferred: [String]? = nil, window: String? = nil) {
        self.kind = kind; self.title = title; self.start = start; self.end = end; self.due = due; self.remind = remind
        self.allDay = allDay; self.people = people; self.place = place; self.inferred = inferred; self.window = window
    }

    func inWindow(_ key: String) -> ExpectedFinding {
        ExpectedFinding(kind: kind, title: title, start: start, end: end, due: due, remind: remind, allDay: allDay, people: people, place: place,
                        inferred: inferred, window: key)
    }
}

public struct GoldenExpected: Sendable, Equatable, Codable {
    public let screenKind: String
    public let tags: [ExpectedTag]?
    public let context: String?
    public let lines: [ExpectedLine]?
    public let findings: [ExpectedFinding]

    public init(screenKind: String, tags: [ExpectedTag]? = nil, context: String? = nil, lines: [ExpectedLine]? = nil,
                findings: [ExpectedFinding]) {
        self.screenKind = screenKind; self.tags = tags; self.context = context; self.lines = lines; self.findings = findings
    }

    enum CodingKeys: String, CodingKey { case screenKind, tags, context, lines, findings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenKind = try c.decode(String.self, forKey: .screenKind)
        tags = try c.decodeIfPresent([ExpectedTag].self, forKey: .tags)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        lines = try c.decodeIfPresent([ExpectedLine].self, forKey: .lines)
        findings = try c.decodeIfPresent([ExpectedFinding].self, forKey: .findings) ?? []
    }
}

public enum GoldenCaseError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingFile(caseName: String, file: String)
    case invalidScreenKind(caseName: String, value: String)
    case unreadable(caseName: String, file: String, reason: String)

    public var description: String {
        switch self {
        case .missingFile(let name, let file): "case \(name): \(file) is missing"
        case .invalidScreenKind(let name, let value): "case \(name): unknown screenKind \"\(value)\""
        case .unreadable(let name, let file, let reason): "case \(name): \(file) cannot be read (\(reason))"
        }
    }
}

/// One golden case: a picture, where and when it was taken, and what a person would find in it.
public struct GoldenCase: Sendable, Equatable {
    public static let pictureFile = "screenshot.png"

    public let name: String
    public let folder: URL
    public let meta: GoldenMeta
    public let expected: GoldenExpected

    public init(name: String, folder: URL, meta: GoldenMeta, expected: GoldenExpected) {
        self.name = name; self.folder = folder; self.meta = meta; self.expected = expected
    }

    public var origin: GoldenOrigin { meta.origin ?? .local }
    public var pictureURL: URL { folder.appendingPathComponent(Self.pictureFile) }

    // MARK: Loading

    public static func load(folder: URL) throws -> GoldenCase {
        let name = folder.lastPathComponent
        func data(_ file: String) throws -> Data {
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw GoldenCaseError.missingFile(caseName: name, file: file) }
            do { return try Data(contentsOf: url) } catch { throw GoldenCaseError.unreadable(caseName: name, file: file, reason: error.localizedDescription) }
        }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(pictureFile).path) else {
            throw GoldenCaseError.missingFile(caseName: name, file: pictureFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta: GoldenMeta, expected: GoldenExpected
        do { meta = try decoder.decode(GoldenMeta.self, from: data("meta.json")) }
        catch let error as GoldenCaseError { throw error }
        catch { throw GoldenCaseError.unreadable(caseName: name, file: "meta.json", reason: "\(error)") }
        do { expected = try decoder.decode(GoldenExpected.self, from: data("expected.json")) }
        catch let error as GoldenCaseError { throw error }
        catch { throw GoldenCaseError.unreadable(caseName: name, file: "expected.json", reason: "\(error)") }
        guard ScreenKind(rawValue: expected.screenKind) != nil else {
            throw GoldenCaseError.invalidScreenKind(caseName: name, value: expected.screenKind)
        }
        return GoldenCase(name: name, folder: folder, meta: meta, expected: expected)
    }

    /// Every case folder under `root` (a folder holding `screenshot.png`), at any depth, in name order.
    /// A folder with `meta.json` or `expected.json` but no picture is skipped with a warning.
    public static func loadAll(in root: URL) throws -> (cases: [GoldenCase], warnings: [String]) {
        var cases: [GoldenCase] = [], warnings: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return ([], []) }
        var folders: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let hasMeta = fm.fileExists(atPath: url.appendingPathComponent("meta.json").path)
            let hasExpected = fm.fileExists(atPath: url.appendingPathComponent("expected.json").path)
            guard hasMeta || hasExpected else { continue }
            if !fm.fileExists(atPath: url.appendingPathComponent(pictureFile).path) {
                warnings.append("skipped \(url.lastPathComponent): no \(pictureFile)")
                continue
            }
            folders.append(url)
        }
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { cases.append(try load(folder: folder)) }
        return (cases, warnings)
    }

    // MARK: Writing

    /// Writes `meta.json`, `expected.json` and the picture. The same case always gives the same bytes.
    public func write(to folder: URL, picture: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"))
        try encoder.encode(expected).write(to: folder.appendingPathComponent("expected.json"))
        try picture.write(to: folder.appendingPathComponent(Self.pictureFile))
    }
}
