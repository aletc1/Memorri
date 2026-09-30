import CoreGraphics
import Foundation

/// What `AnalysisPipeline.analyse` needs for one picture.
public struct PipelineInput: @unchecked Sendable {
    /// What an earlier attempt of the same job already produced.
    public struct Reuse: Sendable {
        public var lines: [RecognisedLine]?
        public var classification: ClassificationResult?
        public init(lines: [RecognisedLine]? = nil, classification: ClassificationResult? = nil) {
            self.lines = lines; self.classification = classification
        }
    }

    /// The full-resolution picture, for reading.
    public let image: CGImage
    /// The picture at about 1024 pixels as JPEG, for the classification call (spike S2).
    public let classificationJPEG: Data
    public let classificationSize: (width: Int, height: Int)
    /// The picture at the configured analysis size as JPEG, for the extraction call.
    public let analysisJPEG: Data
    public let analysisSize: (width: Int, height: Int)
    /// The zone used for dates when no context gives one.
    public let macTimezone: TimeZone
    public let reuse: Reuse

    public init(image: CGImage, classificationJPEG: Data, classificationSize: (width: Int, height: Int), analysisJPEG: Data? = nil,
                analysisSize: (width: Int, height: Int)? = nil, macTimezone: TimeZone = .current, reuse: Reuse = Reuse()) {
        self.image = image; self.classificationJPEG = classificationJPEG; self.classificationSize = classificationSize
        self.analysisJPEG = analysisJPEG ?? classificationJPEG; self.analysisSize = analysisSize ?? classificationSize
        self.macTimezone = macTimezone; self.reuse = reuse
    }
}

/// What one analysis found, step by step (ADR 0014).
public struct AnalysisResult: Sendable {
    public let lines: [RecognisedLine]
    /// Already resolved: an unsure answer is `other`.
    public let classification: ClassificationResult
    public let tags: [CaptureTag]
    public let findings: [Finding]
    /// Findings the model gave that cited no line or a line that does not exist.
    public let discards: [CitationCheck.Discard]
    public let decision: ContextDecision
    public let timezone: TimeZone
    public let timezoneSource: String
    /// True when the line list sent to the model was cut to its maximum.
    public let lineCapApplied: Bool
    public let model: String
    /// The longer side of the picture sent for extraction.
    public let pictureLongEdge: Int
    /// The model calls made in this run (none for a step that was reused), in order.
    public let steps: [StepRecord]

    public init(lines: [RecognisedLine], classification: ClassificationResult, tags: [CaptureTag] = [], findings: [Finding] = [],
                discards: [CitationCheck.Discard] = [], decision: ContextDecision = .unassigned, timezone: TimeZone = .current,
                timezoneSource: String = "mac", lineCapApplied: Bool = false, model: String = "", pictureLongEdge: Int = 0,
                steps: [StepRecord] = []) {
        self.lines = lines; self.classification = classification; self.tags = tags; self.findings = findings; self.discards = discards
        self.decision = decision; self.timezone = timezone; self.timezoneSource = timezoneSource; self.lineCapApplied = lineCapApplied
        self.model = model; self.pictureLongEdge = pictureLongEdge; self.steps = steps
    }
}

/// An analysis that stopped. The steps made so far are kept so the caller can still record the failed call.
public struct AnalysisFailure: Error, Sendable, Equatable {
    public let error: PipelineError
    public let steps: [StepRecord]
}

/// The one way a picture is analysed: the queue job and `memorri-eval` both call it (ADR 0014).
public struct AnalysisPipeline: Sendable {
    private let recogniser: any TextRecogniser
    private let model: any ModelChatting
    private let time: any TimeSource

    public init(recogniser: any TextRecogniser, model: any ModelChatting, time: any TimeSource) {
        self.recogniser = recogniser
        self.model = model
        self.time = time
    }

    /// The read step on its own, so the job can store the lines before any model call.
    public func read(_ image: CGImage) async throws -> [RecognisedLine] {
        do { return try await recogniser.recognise(image) }
        catch { throw AnalysisFailure(error: .transient("text recognition failed"), steps: []) }
    }

    public func analyse(_ input: PipelineInput, settings: ModelStepSettings) async throws -> AnalysisResult {
        var steps: [StepRecord] = []

        let lines: [RecognisedLine]
        if let reused = input.reuse.lines {
            lines = reused
        } else {
            do { lines = try await recogniser.recognise(input.image) }
            catch { throw AnalysisFailure(error: .transient("text recognition failed"), steps: steps) }
        }

        let classification: ClassificationResult
        if let reused = input.reuse.classification {
            classification = reused
        } else {
            let placeholder = "[picture \(input.classificationSize.width)x\(input.classificationSize.height)]"
            let result = await ModelStep.call(using: model, settings: settings, step: "classify", prompt: ExtractionPrompts.classifyPrompt(),
                                              picture: input.classificationJPEG, placeholder: placeholder,
                                              schema: ExtractionSchemas.classifySchema, promptVersion: ExtractionPrompts.classifyVersion,
                                              schemaVersion: ExtractionSchemas.classifySchemaVersion, startedAt: time.now())
            switch result {
            case .failure(let failure):
                steps.append(failure.record)
                throw AnalysisFailure(error: failure.error, steps: steps)
            case .success(let value):
                steps.append(value.record)
                guard let parsed = ClassificationResult.parse(value.value) else {
                    throw AnalysisFailure(error: .transient("invalid answer"), steps: steps)
                }
                classification = parsed
            }
        }
        let resolved = classification.resolved()

        // Extract: the model lists what the picture shows, with literal texts and the lines they come from.
        let (prompt, capped) = ExtractionPrompts.extractPrompt(kind: resolved.kind, lines: lines,
                                                              pictureSize: (input.image.width, input.image.height))
        let placeholder = "[picture \(input.analysisSize.width)x\(input.analysisSize.height)]"
        let extraction = await ModelStep.call(using: model, settings: settings, step: "extract", prompt: prompt, picture: input.analysisJPEG,
                                              placeholder: placeholder, schema: ExtractionSchemas.extractSchema(for: resolved.kind),
                                              promptVersion: ExtractionPrompts.version(for: resolved.kind),
                                              schemaVersion: ExtractionSchemas.schemaVersion(for: resolved.kind), startedAt: time.now())
        let items: [JSONValue]
        switch extraction {
        case .failure(let failure):
            steps.append(failure.record)
            throw AnalysisFailure(error: failure.error, steps: steps)
        case .success(let value):
            steps.append(value.record)
            items = value.value["findings"]?.arrayValue ?? []
        }

        var drafts: [FindingDraft] = [], discards: [CitationCheck.Discard] = []
        for item in items {
            if let draft = FindingDraft.parse(item) { drafts.append(draft) }
            else { discards.append(CitationCheck.Discard(title: item["title"]?.stringValue ?? "", reason: "unreadable finding", citedLines: [])) }
        }
        let checked = CitationCheck.apply(drafts, lineCount: lines.count)
        discards += checked.discarded
        let zone = input.macTimezone
        let findings = checked.kept.map { Self.assemble($0, lines: lines, timezone: zone) }
        return AnalysisResult(lines: lines, classification: resolved, findings: findings, discards: discards, timezone: zone,
                              timezoneSource: "mac", lineCapApplied: capped, model: settings.model,
                              pictureLongEdge: max(input.analysisSize.width, input.analysisSize.height), steps: steps)
    }

    /// Turns a checked draft into a finding. Dates are resolved by `DateResolver`; what it cannot settle stays as written.
    static func assemble(_ draft: FindingDraft, lines: [RecognisedLine], timezone: TimeZone) -> Finding {
        var unresolved: [String: String] = [:]
        func keep(_ field: String, _ texts: [String?]) {
            let text = texts.compactMap { $0 }.joined(separator: " ")
            guard !text.isEmpty, let value = DateResolver.resolve(text: text, field: field).unresolvedText else { return }
            unresolved[field] = value
        }
        keep("start", [draft.dateText, draft.startText])
        keep("end", [draft.endText])
        keep("due", [draft.dueText])
        keep("remind", [draft.remindText])
        return Finding(kind: draft.kind, title: draft.title, allDay: draft.allDay ?? false, timezone: timezone.identifier,
                       people: draft.people, place: draft.place, notes: draft.notes, citedLines: draft.citedLines,
                       confidence: Finding.confidence(citing: draft.citedLines, in: lines, anyInferred: false), unresolved: unresolved)
    }
}
