import Foundation

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

/// What the first model call says about a picture: its kind, and what it looks like.
public struct ClassificationResult: Sendable, Equatable {
    /// Below this confidence a picture counts as `other` (spike S2: nothing below 0.9 was seen on drawn pictures).
    public static let defaultThreshold = 0.5

    /// The kind to use. It equals `modelKind` until `resolved(threshold:)` turns an unsure answer into `other`.
    public let kind: ScreenKind
    /// The kind the model named.
    public let modelKind: ScreenKind
    public let confidence: Double
    public let application: String
    public let platformLook: String
    public let isRemote: Bool
    public let remoteClient: String
    public let theme: String
    public let calendarName: String

    public init(kind: ScreenKind, modelKind: ScreenKind? = nil, confidence: Double, application: String, platformLook: String,
                isRemote: Bool, remoteClient: String, theme: String, calendarName: String) {
        self.kind = kind; self.modelKind = modelKind ?? kind; self.confidence = confidence; self.application = application
        self.platformLook = platformLook; self.isRemote = isRemote; self.remoteClient = remoteClient; self.theme = theme
        self.calendarName = calendarName
    }

    /// Reads an answer that already passed `ExtractionSchemas.classifySchema`.
    public static func parse(_ answer: JSONValue) -> ClassificationResult? {
        guard let kind = answer["screen_kind"]?.stringValue.flatMap(ScreenKind.init(rawValue:)),
              let confidence = answer["kind_confidence"]?.numberValue,
              let application = answer["application"]?.stringValue, let platform = answer["platform_look"]?.stringValue,
              let remote = answer["remote_session"], let isRemote = remote["is_remote"]?.boolValue,
              let client = remote["client"]?.stringValue, let theme = answer["theme"]?.stringValue,
              let calendar = answer["calendar_name"]?.stringValue else { return nil }
        return ClassificationResult(kind: kind, confidence: confidence, application: application, platformLook: platform,
                                    isRemote: isRemote, remoteClient: client, theme: theme, calendarName: calendar)
    }

    /// Reads the raw answer kept in a run record, which may carry the thinking text after a marker.
    public static func parse(storedAnswer: String) -> ClassificationResult? {
        let answer = storedAnswer.components(separatedBy: ModelTestJob.thinkingMarker).first ?? storedAnswer
        guard case .success(let value) = SchemaValidator.validate(answer, against: ExtractionSchemas.classifySchema) else { return nil }
        return parse(value)
    }

    public func withConfidence(_ value: Double) -> ClassificationResult {
        ClassificationResult(kind: kind, modelKind: modelKind, confidence: value, application: application, platformLook: platformLook,
                             isRemote: isRemote, remoteClient: remoteClient, theme: theme, calendarName: calendarName)
    }

    /// An answer the model is not sure about is used as `other`.
    public func resolved(threshold: Double = ClassificationResult.defaultThreshold) -> ClassificationResult {
        ClassificationResult(kind: confidence < threshold ? .other : modelKind, modelKind: modelKind, confidence: confidence,
                             application: application, platformLook: platformLook, isRemote: isRemote, remoteClient: remoteClient,
                             theme: theme, calendarName: calendarName)
    }
}
