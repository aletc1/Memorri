import Foundation

/// What the windows call answered (spec 011, research R2): a judgement per window and the capture-wide fields the classify answer had.
public struct WindowsAnswer: Sendable, Equatable {
    public let judgements: [WindowJudgement]
    /// The calendar name each window showed, by key (empty when none).
    public let calendarNames: [String: String]
    public let application: String
    public let platformLook: String
    public let theme: String
    public let isRemote: Bool
    public let remoteClient: String

    public init(judgements: [WindowJudgement], calendarNames: [String: String] = [:], application: String, platformLook: String, theme: String,
                isRemote: Bool, remoteClient: String) {
        self.judgements = judgements; self.calendarNames = calendarNames; self.application = application; self.platformLook = platformLook
        self.theme = theme; self.isRemote = isRemote; self.remoteClient = remoteClient
    }

    /// Reads an answer that already passed `ExtractionSchemas.windowsSchema`. Nil unless it names exactly the windows in `keys`, each once.
    public static func parse(_ answer: JSONValue, expecting keys: [String]) -> WindowsAnswer? {
        guard let entries = answer["windows"]?.arrayValue, entries.count == keys.count,
              let application = answer["application"]?.stringValue, let platform = answer["platform_look"]?.stringValue,
              let theme = answer["theme"]?.stringValue, let remote = answer["remote_session"], let isRemote = remote["is_remote"]?.boolValue,
              let client = remote["client"]?.stringValue else { return nil }
        var judgements: [WindowJudgement] = [], names: [String: String] = [:]
        for entry in entries {
            guard let key = entry["key"]?.stringValue, let relevant = entry["relevant"]?.boolValue, let kindName = entry["kind"]?.stringValue,
                  let kind = ScreenKind(rawValue: kindName), let confidence = entry["confidence"]?.numberValue, let isRemoteWindow = entry["remote"]?.boolValue,
                  let calendar = entry["calendar_name"]?.stringValue else { return nil }
            judgements.append(WindowJudgement(key: key, relevant: relevant, kind: relevant ? kind : nil, confidence: confidence, remote: isRemoteWindow))
            names[key] = calendar
        }
        guard Set(judgements.map(\.key)) == Set(keys), Set(judgements.map(\.key)).count == keys.count else { return nil }
        return WindowsAnswer(judgements: judgements, calendarNames: names, application: application, platformLook: platform, theme: theme,
                             isRemote: isRemote, remoteClient: client)
    }

    /// Reads the raw answer kept in a run record, which may carry the thinking text after a marker.
    public static func parse(storedAnswer: String, expecting keys: [String]) -> WindowsAnswer? {
        let answer = storedAnswer.components(separatedBy: ModelTestJob.thinkingMarker).first ?? storedAnswer
        guard case .success(let value) = SchemaValidator.validate(answer, against: ExtractionSchemas.windowsSchema(keys: keys)) else { return nil }
        return parse(value, expecting: keys)
    }

    /// Reads a raw answer kept in a run record when the windows it was asked about are not known: the keys are the ones it names. The pipeline
    /// uses it only when they are the windows the picture has now.
    public static func parse(storedAnswer: String) -> WindowsAnswer? {
        let answer = storedAnswer.components(separatedBy: ModelTestJob.thinkingMarker).first ?? storedAnswer
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(answer.utf8)), let entries = value["windows"]?.arrayValue else { return nil }
        let keys = entries.compactMap { $0["key"]?.stringValue }
        guard keys.count == entries.count else { return nil }
        return parse(storedAnswer: storedAnswer, expecting: keys)
    }

    public func judgement(for key: String) -> WindowJudgement? { judgements.first { $0.key == key } }

    /// What the capture as a whole is, for the tags and the context choice that expect a classification: the kind of the frontmost relevant window
    /// (`frontToBack` lists the keys in stack order), else `other`.
    public func classification(frontToBack: [String]) -> ClassificationResult {
        let front = frontToBack.lazy.compactMap { judgement(for: $0) }.first { $0.relevant && $0.kind != nil }
        return ClassificationResult(kind: front?.kind ?? .other, confidence: front?.confidence ?? 1, application: application, platformLook: platformLook,
                                    isRemote: isRemote, remoteClient: remoteClient, theme: theme, calendarName: front.flatMap { calendarNames[$0.key] } ?? "")
    }
}
