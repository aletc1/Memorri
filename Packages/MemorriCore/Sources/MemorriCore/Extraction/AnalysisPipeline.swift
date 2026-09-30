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
    /// When the picture was captured: "today" and "tomorrow" in it are relative to this, in the zone of the picture.
    public let captureTime: Date
    /// The languages date texts are read in, first choice first.
    public let locales: [Locale]
    public let reuse: Reuse

    /// The Mac's languages, then English and Spanish.
    public static func defaultLocales() -> [Locale] {
        (Locale.preferredLanguages.prefix(3).map { Locale(identifier: $0) } + [Locale(identifier: "en_US"), Locale(identifier: "es_ES")])
    }

    public init(image: CGImage, classificationJPEG: Data, classificationSize: (width: Int, height: Int), analysisJPEG: Data? = nil,
                analysisSize: (width: Int, height: Int)? = nil, macTimezone: TimeZone = .current, captureTime: Date = Date(),
                locales: [Locale] = PipelineInput.defaultLocales(), reuse: Reuse = Reuse()) {
        self.image = image; self.classificationJPEG = classificationJPEG; self.classificationSize = classificationSize
        self.analysisJPEG = analysisJPEG ?? classificationJPEG; self.analysisSize = analysisSize ?? classificationSize
        self.macTimezone = macTimezone; self.captureTime = captureTime; self.locales = locales; self.reuse = reuse
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
        let calendarKind = resolved.kind == .calendarWeek || resolved.kind == .calendarDay
        let headers = calendarKind ? DateResolver.headers(in: lines, locales: input.locales, reference: input.captureTime, timezone: zone) : []
        let order = DateParser.dateOrder(ofUnambiguous: lines.map(\.text))
        let base = ResolutionContext(captureTime: input.captureTime, timezone: zone, headers: headers, lines: lines, dateOrder: order,
                                     locales: input.locales)
        let geometry = calendarKind ? Geometry(image: input.image, columnWidth: Self.columnWidth(headers: headers, imageWidth: input.image.width,
                                                                                                  kind: resolved.kind)) : nil
        let findings = checked.kept.map { Self.assemble($0, lines: lines, context: base, geometry: geometry) }
        return AnalysisResult(lines: lines, classification: resolved, findings: findings, discards: discards, timezone: zone,
                              timezoneSource: "mac", lineCapApplied: capped, model: settings.model,
                              pictureLongEdge: max(input.analysisSize.width, input.analysisSize.height), steps: steps)
    }

    /// What the duration step needs from a calendar view: the picture and the width of one column of blocks.
    struct Geometry {
        let image: CGImage
        let columnWidth: Int
    }

    /// The median spacing of the date headers, else a seventh of the picture for a week and the whole width for a day.
    static func columnWidth(headers: [DateHeader], imageWidth: Int, kind: ScreenKind) -> Int {
        let gaps = zip(headers, headers.dropFirst()).map { $1.midX - $0.midX }.sorted()
        if !gaps.isEmpty { return max(1, Int(gaps[gaps.count / 2])) }
        return kind == .calendarWeek ? imageWidth / 7 : imageWidth
    }

    /// Turns a checked draft into a finding. Each date text is resolved by `DateResolver`; what it cannot settle stays as written.
    static func assemble(_ draft: FindingDraft, lines: [RecognisedLine], context base: ResolutionContext, geometry: Geometry? = nil) -> Finding {
        // An email's own date is the reference for the words in it.
        let context = ResolutionContext(captureTime: base.captureTime, timezone: base.timezone, headers: base.headers, lines: base.lines,
                                        dateOrder: base.dateOrder, locales: base.locales,
                                        sentReference: DateResolver.sentReference(for: draft, in: base))
        func resolve(_ field: String, _ texts: String?...) -> ResolvedValue {
            let text = texts.lazy.compactMap { $0 }.first ?? ""
            return DateResolver.resolve(text: text, field: field, draft: draft, in: context)
        }
        var results: [String: ResolvedValue] = [:]
        switch draft.kind {
        case .appointment:
            results["start"] = resolve("start", draft.startText, draft.dateText)
            results["end"] = resolve("end", draft.endText)
            if draft.dueText != nil { results["due"] = resolve("due", draft.dueText) }
            results["remind"] = resolve("remind", draft.remindText)
        case .task, .deadline:
            results["due"] = resolve("due", draft.dueText, draft.dateText, draft.startText)
            results["remind"] = resolve("remind", draft.remindText)
        case .reminder:
            results["remind"] = resolve("remind", draft.remindText, draft.startText, draft.dateText, draft.dueText)
            if draft.dueText != nil { results["due"] = resolve("due", draft.dueText) }
        }
        // An appointment with a start and no end gets one: from its block's height, else one hour, never past midnight.
        if draft.kind == .appointment, draft.endText == nil, let start = results["start"], let begins = start.date, !start.allDay, draft.allDay != true {
            var minutes = 60, reason = "default-60"
            if let geometry, let title = draft.citedLines.compactMap({ n in lines.first { $0.n == n } }).min(by: { $0.box.y < $1.box.y }),
               let measured = BlockGeometry.duration(titleBox: title.box, lines: lines, image: geometry.image, columnWidth: geometry.columnWidth) {
                minutes = measured; reason = "block-height"
            }
            var end = begins.addingTimeInterval(Double(minutes) * 60)
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = context.timezone
            if let midnight = zoned.date(byAdding: .day, value: 1, to: zoned.startOfDay(for: begins)), end > midnight { end = midnight; reason = "end-of-day" }
            results["end"] = ResolvedValue(date: end, allDay: false, provenance: FieldProvenance(origin: .inferred, rule: reason, reason: reason),
                                           unresolvedText: nil)
        }
        var provenance: [String: FieldProvenance] = [:], unresolved: [String: String] = [:]
        for (field, value) in results {
            if let p = value.provenance { provenance[field] = p }
            if let text = value.unresolvedText { unresolved[field] = text }
        }
        let primary = results["start"] ?? results["due"] ?? results["remind"]
        let allDay = draft.allDay ?? (primary?.date != nil ? primary!.allDay : false)
        let anyInferred = provenance.values.contains { $0.origin == .inferred }
        return Finding(kind: draft.kind, title: draft.title, allDay: allDay, start: results["start"]?.date, end: results["end"]?.date,
                       due: results["due"]?.date, remind: results["remind"]?.date, timezone: context.timezone.identifier,
                       people: draft.people, place: draft.place, notes: draft.notes, citedLines: draft.citedLines,
                       confidence: Finding.confidence(citing: draft.citedLines, in: lines, anyInferred: anyInferred),
                       provenance: provenance, unresolved: unresolved)
    }
}
