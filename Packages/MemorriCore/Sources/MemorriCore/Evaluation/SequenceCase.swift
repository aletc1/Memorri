import Foundation

public enum SequenceCaseError: Error, CustomStringConvertible, Equatable {
    case invalid(case: String, reason: String)
    case noCases(String)

    public var description: String {
        switch self {
        case .invalid(let name, let reason): "sequence case \(name): \(reason)"
        case .noCases(let path): "no sequence cases found in \(path)"
        }
    }
}

/// Several sightings of the same events over time, with what the user did, and which event each finding stands for. The input of
/// `memorri-eval reconcile` (contracts/eval-cli.md). Invented titles only.
public struct SequenceCase: Sendable, Equatable, Codable {
    public struct ContextSpec: Sendable, Equatable, Codable {
        public let id: String
        public let name: String
        public let timezone: String?
        public init(id: String, name: String, timezone: String?) { self.id = id; self.name = name; self.timezone = timezone }
    }

    public struct FindingSpec: Sendable, Equatable, Codable {
        /// The real-world event this finding is a sighting of: findings with the same event should end in one item.
        public let event: String
        public let kind: FindingKind
        public let title: String
        /// The language the title is written in; two sightings of one event in different languages are a translated pair.
        public let lang: String?
        public let start: Date?
        public let end: Date?
        public let due: Date?
        public let allDay: Bool
        public let inferred: [String]
        public let confidence: Double
        public let place: String?
        public let people: [String]

        public init(event: String, kind: FindingKind, title: String, lang: String? = nil, start: Date? = nil, end: Date? = nil, due: Date? = nil,
                    allDay: Bool = false, inferred: [String] = [], confidence: Double = 0.9, place: String? = nil, people: [String] = []) {
            self.event = event; self.kind = kind; self.title = title; self.lang = lang; self.start = start; self.end = end; self.due = due
            self.allDay = allDay; self.inferred = inferred; self.confidence = confidence; self.place = place; self.people = people
        }

        enum CodingKeys: String, CodingKey { case event, kind, title, lang, start, end, due, allDay, inferred, confidence, place, people }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(event: try c.decode(String.self, forKey: .event), kind: try c.decode(FindingKind.self, forKey: .kind),
                      title: try c.decode(String.self, forKey: .title), lang: try c.decodeIfPresent(String.self, forKey: .lang),
                      start: try c.decodeIfPresent(Date.self, forKey: .start), end: try c.decodeIfPresent(Date.self, forKey: .end),
                      due: try c.decodeIfPresent(Date.self, forKey: .due), allDay: try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false,
                      inferred: try c.decodeIfPresent([String].self, forKey: .inferred) ?? [],
                      confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.9,
                      place: try c.decodeIfPresent(String.self, forKey: .place), people: try c.decodeIfPresent([String].self, forKey: .people) ?? [])
        }
    }

    public struct CaptureSpec: Sendable, Equatable, Codable {
        public let id: String
        public let capturedAt: Date
        public let context: String?
        public let findings: [FindingSpec]
        public init(id: String, capturedAt: Date, context: String? = nil, findings: [FindingSpec]) {
            self.id = id; self.capturedAt = capturedAt; self.context = context; self.findings = findings
        }
    }

    public enum ActionKind: String, Sendable, Equatable, Codable { case dismiss, restore, editTitle, split }

    /// Something the user does after a capture has been reconciled.
    public struct Action: Sendable, Equatable, Codable {
        public let after: String
        public let action: ActionKind
        public let event: String
        /// The new title, for `editTitle`.
        public let title: String?
        public init(after: String, action: ActionKind, event: String, title: String? = nil) {
            self.after = after; self.action = action; self.event = event; self.title = title
        }
    }

    public var name: String
    public let macTimezone: String
    public let contexts: [ContextSpec]
    public let captures: [CaptureSpec]
    public let actions: [Action]

    public init(name: String, macTimezone: String, contexts: [ContextSpec], captures: [CaptureSpec], actions: [Action] = []) {
        self.name = name; self.macTimezone = macTimezone; self.contexts = contexts; self.captures = captures; self.actions = actions
    }

    enum CodingKeys: String, CodingKey { case macTimezone, contexts, captures, actions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: "", macTimezone: try c.decode(String.self, forKey: .macTimezone), contexts: try c.decode([ContextSpec].self, forKey: .contexts),
                  captures: try c.decode([CaptureSpec].self, forKey: .captures), actions: try c.decodeIfPresent([Action].self, forKey: .actions) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(macTimezone, forKey: .macTimezone); try c.encode(contexts, forKey: .contexts)
        try c.encode(captures, forKey: .captures); try c.encode(actions, forKey: .actions)
    }

    // MARK: Files

    public static func decode(_ data: Data, name: String) throws -> SequenceCase {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var value: SequenceCase
        do { value = try decoder.decode(SequenceCase.self, from: data) }
        catch let error as DecodingError { throw SequenceCaseError.invalid(case: name, reason: describe(error)) }
        value.name = name
        try value.validate()
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// Every folder with a `sequence.json`, by folder name.
    public static func loadAll(in folder: URL) throws -> [SequenceCase] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { throw SequenceCaseError.noCases(folder.path) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let cases = try names.compactMap { name -> SequenceCase? in
            let file = folder.appendingPathComponent(name).appendingPathComponent("sequence.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decode(Data(contentsOf: file), name: name)
        }
        if cases.isEmpty { throw SequenceCaseError.noCases(folder.path) }
        return cases
    }

    private func validate() throws {
        let captureIDs = Set(captures.map(\.id)), contextIDs = Set(contexts.map(\.id))
        for capture in captures {
            if let context = capture.context, !contextIDs.contains(context) {
                throw SequenceCaseError.invalid(case: name, reason: "capture \(capture.id) names the unknown context \(context)")
            }
        }
        for action in actions {
            if !captureIDs.contains(action.after) { throw SequenceCaseError.invalid(case: name, reason: "an action comes after the unknown capture \(action.after)") }
            if action.action == .editTitle && action.title == nil { throw SequenceCaseError.invalid(case: name, reason: "editTitle for \(action.event) needs a title") }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context).isEmpty ? "" : path(context) + ": ")missing \"\(key.stringValue)\""
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}
