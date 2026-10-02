import CoreGraphics
import Foundation

/// What `AnalysisPipeline.analyse` needs for one picture.
public struct PipelineInput: @unchecked Sendable {
    /// What an earlier attempt of the same job already produced.
    public struct Reuse: Sendable {
        public var lines: [RecognisedLine]?
        public var classification: ClassificationResult?
        /// The stored answer of the windows call; used when it names the windows the picture has now.
        public var windows: WindowsAnswer?
        /// The `findings` list a window's earlier extraction answered, by window key; used only together with a reused windows answer.
        public var extractions: [String: [JSONValue]] = [:]
        public init(lines: [RecognisedLine]? = nil, classification: ClassificationResult? = nil, windows: WindowsAnswer? = nil,
                    extractions: [String: [JSONValue]] = [:]) {
            self.lines = lines; self.classification = classification; self.windows = windows; self.extractions = extractions
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
    /// The user's contexts, to pick the one this picture belongs to and to take its time zone from.
    public let contexts: [ContextRecord]
    /// The windows that were visible when the picture was taken.
    public let windows: [WindowInfo]
    /// What the user chose for this picture (a decision with source `user`); it is used as it is and never replaced.
    public let userChoice: ContextDecision?
    /// The display's scale factor (2 on a Retina display), when known.
    public let displayScale: Double?

    /// The Mac's languages, then English and Spanish.
    public static func defaultLocales() -> [Locale] {
        (Locale.preferredLanguages.prefix(3).map { Locale(identifier: $0) } + [Locale(identifier: "en_US"), Locale(identifier: "es_ES")])
    }

    public init(image: CGImage, classificationJPEG: Data, classificationSize: (width: Int, height: Int), analysisJPEG: Data? = nil,
                analysisSize: (width: Int, height: Int)? = nil, macTimezone: TimeZone = .current, captureTime: Date = Date(),
                locales: [Locale] = PipelineInput.defaultLocales(), reuse: Reuse = Reuse(), contexts: [ContextRecord] = [],
                windows: [WindowInfo] = [], userChoice: ContextDecision? = nil, displayScale: Double? = nil) {
        self.image = image; self.classificationJPEG = classificationJPEG; self.classificationSize = classificationSize
        self.analysisJPEG = analysisJPEG ?? classificationJPEG; self.analysisSize = analysisSize ?? classificationSize
        self.macTimezone = macTimezone; self.captureTime = captureTime; self.locales = locales; self.reuse = reuse
        self.contexts = contexts; self.windows = windows; self.userChoice = userChoice; self.displayScale = displayScale
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
    /// The version of the code that read the findings when the model did not (a month grid); nil when the model did.
    public let readBy: String?
    /// The windows the picture was split into and what each was judged to be; empty when it was read as one picture (no stack, or the old path).
    public let windows: [WindowReadingRecord]
    /// The clock relative dates were resolved against; nil when the capture time was used without looking for a clock (the old path).
    public let reference: ReferenceClock?
    /// How many windows were read; 1 for a picture read as one.
    public let windowsRead: Int

    public init(lines: [RecognisedLine], classification: ClassificationResult, tags: [CaptureTag] = [], findings: [Finding] = [],
                discards: [CitationCheck.Discard] = [], decision: ContextDecision = .unassigned, timezone: TimeZone = .current,
                timezoneSource: String = "mac", lineCapApplied: Bool = false, model: String = "", pictureLongEdge: Int = 0,
                steps: [StepRecord] = [], readBy: String? = nil, windows: [WindowReadingRecord] = [], reference: ReferenceClock? = nil,
                windowsRead: Int? = nil) {
        self.windows = windows; self.reference = reference; self.windowsRead = windowsRead ?? 1
        self.readBy = readBy
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

        // A desktop with several windows is read window by window (spec 011); anything else, and a windows call that fails or answers badly,
        // is read as one picture, as before.
        let screen = VisibleScreen.split(lines: lines, windows: input.windows, pictureWidth: input.image.width, pictureHeight: input.image.height)
        if screen.perWindow {
            if let (answer, reused) = try await judgeWindows(screen, input: input, settings: settings, steps: &steps) {
                return try await analyseWindows(screen, answer: answer, reusable: reused ? input.reuse.extractions : [:], lines: lines, input: input,
                                                settings: settings, steps: steps)
            }
        }
        return try await analyseWhole(input, lines: lines, settings: settings, steps: steps)
    }

    /// The picture as one: classify, then extract (the analysis before spec 011).
    private func analyseWhole(_ input: PipelineInput, lines: [RecognisedLine], settings: ModelStepSettings, steps firstSteps: [StepRecord]) async throws -> AnalysisResult {
        var steps = firstSteps

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
        let first = classification.resolved()

        // What the picture's surroundings say: tags from the capture, the text and the first call. They feed the context choice,
        // and the context decides the time zone the dates are read in, so both are settled before the dates are resolved.
        let tags = TagExtractor.tags(width: input.image.width, height: input.image.height, scale: input.displayScale, windows: input.windows,
                                     lines: lines, classification: first)
        let decision = input.userChoice.flatMap { $0.source == .user ? $0 : nil }
            ?? ContextMatcher.decide(contexts: input.contexts, windows: input.windows, tags: tags, lines: lines)
        let (zone, zoneSource) = Self.zone(for: input.contexts.first { $0.id == decision.contextID }, mac: input.macTimezone)
        let locales = Self.locales(input.locales, preferring: tags.first { $0.key == "language" }?.value)
        let resolved = Self.corrected(first, lines: lines, locales: locales, reference: input.captureTime, zone: zone)
        let calendarKind = resolved.kind == .calendarWeek || resolved.kind == .calendarDay
        var headers = calendarKind ? DateResolver.headers(in: lines, locales: locales, reference: input.captureTime, timezone: zone) : []
        var cells = resolved.kind == .calendarMonth ? DateResolver.monthCells(in: lines, locales: locales, reference: input.captureTime, timezone: zone) : []
        // A desktop shows several windows. Once the calendar's grid is found, its title, month labels and day numbers are looked for again
        // in that window alone, so the text of another window cannot name the month (spec 006 follow-up, postmortem 2026-10-01).
        if let anchor = cells.first ?? headers.first, let own = SubjectRegion.visibleLines(lines, around: (anchor.midX, anchor.midY), windows: input.windows),
           own.count < lines.count {
            if resolved.kind == .calendarMonth {
                let narrowed = DateResolver.monthCells(in: own, locales: locales, reference: input.captureTime, timezone: zone)
                if narrowed.count >= MonthEntries.minimumCells { cells = narrowed }
            } else if calendarKind {
                let narrowed = DateResolver.headers(in: own, locales: locales, reference: input.captureTime, timezone: zone)
                if narrowed.count >= headers.count { headers = narrowed }
            }
        }
        let order = tags.first { $0.key == "date_order" }.flatMap { DateOrder(rawValue: $0.value) }
        let base = ResolutionContext(captureTime: input.captureTime, timezone: zone, headers: headers, lines: lines, dateOrder: order,
                                     locales: locales, cells: cells)

        // Extract: the model lists what the picture shows, with literal texts and the lines they come from.
        // Only the calendar's own grid goes to the model when other windows share the picture.
        let shown = SubjectRegion.lines(lines, kind: resolved.kind, headers: headers, cells: cells, windows: input.windows)
        // A month grid is read from its lines and cells, with no model call (ADR 0018); anything else goes to the model.
        let byGeometry = resolved.kind == .calendarMonth && cells.count >= MonthEntries.minimumCells
        var capped = false
        var drafts: [FindingDraft] = [], discards: [CitationCheck.Discard] = []
        if byGeometry {
            drafts = MonthEntries.drafts(lines: shown, cells: cells, locales: locales)
        } else {
            let (prompt, wasCapped) = ExtractionPrompts.extractPrompt(kind: resolved.kind, lines: shown,
                                                                      pictureSize: (input.image.width, input.image.height))
            capped = wasCapped
            // A long list takes the model longer to write out: wait in proportion, never less than the configured time.
            let extractSettings = ModelStepSettings(model: settings.model, think: settings.think,
                                                    timeout: max(settings.timeout, min(900, 90 + 1.5 * Double(shown.count))), modelThinks: settings.modelThinks)
            let placeholder = "[picture \(input.analysisSize.width)x\(input.analysisSize.height)]"
            let extraction = await ModelStep.call(using: model, settings: extractSettings, step: "extract", prompt: prompt, picture: input.analysisJPEG,
                                                  placeholder: placeholder, schema: ExtractionSchemas.extractSchema(for: resolved.kind),
                                                  promptVersion: ExtractionPrompts.version(for: resolved.kind),
                                                  schemaVersion: ExtractionSchemas.schemaVersion(for: resolved.kind), startedAt: time.now(),
                                                  maxTokens: Self.answerLimit(lines: shown.count, modelThinks: settings.modelThinks))
            let items: [JSONValue]
            switch extraction {
            case .failure(let failure):
                steps.append(failure.record)
                throw AnalysisFailure(error: failure.error, steps: steps)
            case .success(let value):
                steps.append(value.record)
                items = value.value["findings"]?.arrayValue ?? []
            }
            for item in items {
                if let draft = FindingDraft.parse(item) {
                    let inCalendar = resolved.kind == .calendarMonth || calendarKind
                    let appointment = (inCalendar && draft.kind != .appointment ? draft.asAppointment() : draft).splittingTimeRange()
                    drafts.append(resolved.kind == .calendarMonth ? Self.withRowTime(appointment, lines: lines, cells: cells, locales: locales) : appointment)
                }
                else { discards.append(CitationCheck.Discard(title: item["title"]?.stringValue ?? "", reason: "unreadable finding", citedLines: [])) }
            }
        }
        let checked = CitationCheck.apply(drafts, lineCount: lines.count)
        discards += checked.discarded
        let geometry = calendarKind ? Geometry(image: input.image, columnWidth: Self.columnWidth(headers: headers, imageWidth: input.image.width,
                                                                                                  kind: resolved.kind)) : nil
        let findings = checked.kept.map { Self.assemble($0, lines: lines, context: base, geometry: geometry, tags: tags) }
        return AnalysisResult(lines: lines, classification: resolved, tags: tags, findings: findings, discards: discards, decision: decision,
                              timezone: zone, timezoneSource: zoneSource, lineCapApplied: capped, model: settings.model,
                              pictureLongEdge: max(input.analysisSize.width, input.analysisSize.height), steps: steps,
                              readBy: byGeometry ? MonthEntries.version : nil)
    }

    // MARK: Windows (spec 011)

    /// The windows call: which windows can hold events and what kind of view each is. Nil (and the failure recorded in `steps`) when the call
    /// fails or does not name the windows given; the caller then reads the picture as one. A server that is gone stops the analysis.
    private func judgeWindows(_ screen: VisibleScreen, input: PipelineInput, settings: ModelStepSettings, steps: inout [StepRecord]) async throws -> (WindowsAnswer, reused: Bool)? {
        let keys = screen.windows.map(\.key)
        if let reused = input.reuse.windows, Set(reused.judgements.map(\.key)) == Set(keys), reused.judgements.count == keys.count { return (reused, true) }
        let placeholder = "[picture \(input.classificationSize.width)x\(input.classificationSize.height)]"
        let result = await ModelStep.call(using: model, settings: settings, step: "windows", prompt: ExtractionPrompts.windowsPrompt(windows: screen.windows),
                                          picture: input.classificationJPEG, placeholder: placeholder, schema: ExtractionSchemas.windowsSchema(keys: keys),
                                          promptVersion: ExtractionPrompts.windowsVersion, schemaVersion: ExtractionSchemas.windowsSchemaVersion,
                                          startedAt: time.now())
        switch result {
        case .failure(let failure):
            steps.append(failure.record)
            if failure.error == .serverUnavailable { throw AnalysisFailure(error: .serverUnavailable, steps: steps) }
            return nil
        case .success(let value):
            guard let answer = WindowsAnswer.parse(value.value, expecting: keys) else {
                steps.append(value.record.failing("answer does not name the windows"))
                return nil
            }
            steps.append(value.record)
            return (answer, false)
        }
    }

    /// Each window the model called relevant is read on its own: its lines, its dates, its picture. Month grids are read from their geometry.
    private func analyseWindows(_ screen: VisibleScreen, answer: WindowsAnswer, reusable: [String: [JSONValue]], lines: [RecognisedLine], input: PipelineInput,
                                settings: ModelStepSettings, steps firstSteps: [StepRecord]) async throws -> AnalysisResult {
        var steps = firstSteps
        let first = answer.classification(frontToBack: screen.windows.map(\.key)).resolved()
        let tags = TagExtractor.tags(width: input.image.width, height: input.image.height, scale: input.displayScale, windows: input.windows,
                                     lines: lines, classification: first)
        let decision = input.userChoice.flatMap { $0.source == .user ? $0 : nil }
            ?? ContextMatcher.decide(contexts: input.contexts, windows: input.windows, tags: tags, lines: lines)
        let (zone, zoneSource) = Self.zone(for: input.contexts.first { $0.id == decision.contextID }, mac: input.macTimezone)
        let locales = Self.locales(input.locales, preferring: tags.first { $0.key == "language" }?.value)
        let order = tags.first { $0.key == "date_order" }.flatMap { DateOrder(rawValue: $0.value) }
        let fullLongEdge = max(1, max(input.image.width, input.image.height))
        let analysisLongEdge = max(input.analysisSize.width, input.analysisSize.height)

        var findings: [Finding] = [], discards: [CitationCheck.Discard] = []
        var capped = false, modelReads = 0, geometryReads = 0, windowsRead = 0
        var reference: ReferenceClock?
        var frontKind: ScreenKind?            // what the frontmost relevant window turned out to be, after the geometry check
        for window in screen.windows {
            guard let judgement = answer.judgement(for: window.key), judgement.relevant else { continue }
            windowsRead += 1
            let ownClass = ClassificationResult(kind: judgement.kind ?? .other, confidence: judgement.confidence, application: first.application,
                                                platformLook: first.platformLook, isRemote: first.isRemote, remoteClient: first.remoteClient,
                                                theme: first.theme, calendarName: answer.calendarNames[window.key] ?? "").resolved()
            // What "today" is for this window: the clock of its own surroundings (a remote desktop), else the screen's, else the capture's time.
            let clock = ReferenceClock.find(window: window, remote: judgement.remote, screen: screen, captureTime: input.captureTime, timezone: zone,
                                            pictureHeight: input.image.height, locales: locales)
            reference = reference ?? clock
            let resolved = Self.corrected(ownClass, lines: window.lines, locales: locales, reference: clock.instant, zone: zone, dayWithManyHeadersIsAWeek: true)
            frontKind = frontKind ?? resolved.kind
            let calendarKind = resolved.kind == .calendarWeek || resolved.kind == .calendarDay
            // The dates are read from this window's own text only.
            let headers = calendarKind ? DateResolver.headers(in: window.lines, locales: locales, reference: clock.instant, timezone: zone) : []
            let cells = resolved.kind == .calendarMonth ? DateResolver.monthCells(in: window.lines, locales: locales, reference: clock.instant, timezone: zone) : []
            let base = ResolutionContext(captureTime: input.captureTime, timezone: zone, headers: headers, lines: window.lines, dateOrder: order,
                                         locales: locales, cells: cells, clock: clock)
            let shown = SubjectRegion.lines(window.lines, kind: resolved.kind, headers: headers, cells: cells)
            var drafts: [FindingDraft] = []
            var ownDiscards: [CitationCheck.Discard] = []
            if resolved.kind == .calendarMonth, cells.count >= MonthEntries.minimumCells {
                drafts = MonthEntries.drafts(lines: shown, cells: cells, locales: locales)
                geometryReads += 1
            } else {
                let (prompt, wasCapped) = ExtractionPrompts.extractPrompt(kind: resolved.kind, lines: shown, pictureSize: (input.image.width, input.image.height), windowed: true)
                capped = capped || wasCapped
                var items: [JSONValue]
                if let stored = reusable[window.key] {
                    items = stored                       // what an earlier attempt of this window answered: no call
                } else {
                    let extractSettings = ModelStepSettings(model: settings.model, think: settings.think,
                                                            timeout: max(settings.timeout, min(900, 90 + 1.5 * Double(shown.count))), modelThinks: settings.modelThinks)
                    let cut = Self.windowPicture(input.image, frame: window.frame, longEdge: analysisLongEdge, fullLongEdge: fullLongEdge)
                    let extraction = await ModelStep.call(using: model, settings: extractSettings, step: "extract:\(window.key)", prompt: prompt,
                                                          picture: cut?.jpeg ?? input.analysisJPEG,
                                                          placeholder: "[picture \(cut?.size.width ?? input.analysisSize.width)x\(cut?.size.height ?? input.analysisSize.height)]",
                                                          schema: ExtractionSchemas.extractSchema(for: resolved.kind),
                                                          promptVersion: ExtractionPrompts.version(for: resolved.kind, windowed: true),
                                                          schemaVersion: ExtractionSchemas.schemaVersion(for: resolved.kind), startedAt: time.now(),
                                                          maxTokens: Self.answerLimit(lines: shown.count, modelThinks: settings.modelThinks))
                    switch extraction {
                    case .failure(let failure):
                        steps.append(failure.record)
                        throw AnalysisFailure(error: failure.error, steps: steps)
                    case .success(let value):
                        steps.append(value.record)
                        items = value.value["findings"]?.arrayValue ?? []
                    }
                }
                modelReads += 1
                for item in items {
                    if let draft = FindingDraft.parse(item) {
                        let inCalendar = resolved.kind == .calendarMonth || calendarKind
                        let appointment = (inCalendar && draft.kind != .appointment ? draft.asAppointment() : draft).splittingTimeRange()
                        drafts.append(resolved.kind == .calendarMonth ? Self.withRowTime(appointment, lines: window.lines, cells: cells, locales: locales) : appointment)
                    } else { ownDiscards.append(CitationCheck.Discard(title: item["title"]?.stringValue ?? "", reason: "unreadable finding", citedLines: [])) }
                }
            }
            let checked = CitationCheck.apply(Self.mergingRepeats(drafts), lineCount: lines.count, allowed: Set(window.lines.map(\.n)))
            discards += ownDiscards + checked.discarded
            let geometry = calendarKind ? Geometry.cut(of: input.image, frame: window.frame,
                                                       columnWidth: Self.columnWidth(headers: headers, imageWidth: window.frame.width, kind: resolved.kind)) : nil
            findings += checked.kept.map { Self.assemble($0, lines: window.lines, context: base, geometry: geometry, tags: tags, windowKey: window.key) }
        }
        let now = time.now()
        let records = screen.windows.map { window -> WindowReadingRecord in
            let judgement = answer.judgement(for: window.key)
            return WindowReadingRecord(imageID: "", windowKey: window.key, appName: window.appName, title: window.title, frame: window.frame, visible: window.visible,
                                       visibleShare: window.visibleShare, relevant: judgement?.relevant ?? false, kind: judgement?.kind,
                                       confidence: judgement?.confidence ?? 0, remote: judgement?.remote ?? false, runID: nil,
                                       promptVersion: ExtractionPrompts.windowsVersion, createdAt: now)
        }
        return AnalysisResult(lines: lines, classification: frontKind.map { first.withKind($0) } ?? first, tags: tags, findings: findings, discards: discards,
                              decision: decision, timezone: zone,
                              timezoneSource: zoneSource, lineCapApplied: capped, model: settings.model, pictureLongEdge: analysisLongEdge, steps: steps,
                              readBy: modelReads == 0 && geometryReads > 0 ? MonthEntries.version : nil, windows: records,
                              reference: reference ?? ReferenceClock.find(window: nil, remote: false, screen: screen, captureTime: input.captureTime, timezone: zone,
                                                                          pictureHeight: input.image.height, locales: locales),
                              windowsRead: windowsRead)
    }

    /// A model sometimes lists one block twice, the second time for its place (a calendar block has a title, a time and a room): findings of
    /// one window with the same title that cite a line in common are one, with what each gave.
    static func mergingRepeats(_ drafts: [FindingDraft]) -> [FindingDraft] {
        var result: [FindingDraft] = []
        for draft in drafts {
            let title = TitleNormaliser.normalise(draft.title)
            if let index = result.firstIndex(where: { TitleNormaliser.normalise($0.title) == title && !Set($0.citedLines).isDisjoint(with: draft.citedLines) }) {
                result[index] = result[index].filling(from: draft)
            } else { result.append(draft) }
        }
        return result
    }

    /// The part of the full picture a window covers, as JPEG, at the pixel density of the analysis copy (never enlarged): what a window's
    /// extraction is sent instead of the whole screen. Nil when the picture cannot be cut.
    static func windowPicture(_ image: CGImage, frame: PixelBox, longEdge: Int, fullLongEdge: Int) -> (jpeg: Data, size: (width: Int, height: Int))? {
        let x0 = max(0, frame.x), y0 = max(0, frame.y), x1 = min(image.width, frame.x + frame.width), y1 = min(image.height, frame.y + frame.height)
        guard x1 > x0, y1 > y0, let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return nil }
        let scale = min(1, Double(longEdge) / Double(fullLongEdge))
        var picture = cropped
        if scale < 1 {
            let width = max(1, Int((Double(cropped.width) * scale).rounded())), height = max(1, Int((Double(cropped.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            picture = scaled
        }
        guard let jpeg = try? PictureConverter.jpegData(from: picture) else { return nil }
        return (jpeg, (picture.width, picture.height))
    }

    /// True when the end text is written in a cited line that is not just a clock label of the hour scale at the side.
    static func endIsShown(_ text: String?, in cited: [Int], lines: [RecognisedLine]) -> Bool {
        guard let wanted = text?.filter({ !$0.isWhitespace }).lowercased(), !wanted.isEmpty else { return false }
        return cited.compactMap { n in lines.first { $0.n == n } }.contains { line in
            guard !DateResolver.isClockLabel(line.text) else { return false }
            return line.text.filter { !$0.isWhitespace }.lowercased().contains(wanted)
        }
    }

    /// The cited line that is the block's own first line: not a clock label of the scale, not a date header (models often cite the
    /// header too), and preferably the one that shows the start time, else the one with the title.
    static func blockTitleLine(_ draft: FindingDraft, lines: [RecognisedLine], headers: [DateHeader], locales: [Locale] = []) -> RecognisedLine? {
        let skipped = Set(headers.map(\.line))
        let candidates = draft.citedLines.compactMap { n in lines.first { $0.n == n } }
            .filter { !DateResolver.isClockLabel($0.text) && !skipped.contains($0.n) && (locales.isEmpty || !DateResolver.isCellLabel($0.text, locales: locales)) }
        func compact(_ text: String?) -> String { (text ?? "").filter { !$0.isWhitespace }.lowercased() }
        if let start = draft.startText.map(compact), !start.isEmpty, let line = candidates.first(where: { compact($0.text).contains(start) }) { return line }
        let title = compact(draft.title)
        if !title.isEmpty, let line = candidates.first(where: { compact($0.text).contains(title) }) { return line }
        return candidates.min { $0.box.y < $1.box.y }
    }

    /// In a month view an entry's time is written on its own row, at the right of its cell, and the model often takes another one
    /// (the neighbouring cell's) or none. The time is read from the row: a line that is only a time, at the height of the entry's
    /// own line, to its right and inside its cell; else a time at the end of the entry's own line. An entry with no time on its row
    /// has none (it is all day).
    static func withRowTime(_ draft: FindingDraft, lines: [RecognisedLine], cells: [DateHeader], locales: [Locale]) -> FindingDraft {
        guard !cells.isEmpty, let title = blockTitleLine(draft, lines: lines, headers: cells, locales: locales) else { return draft }
        let range = NSRange(title.text.startIndex..., in: title.text)
        for expression in [trailingClock, leadingClock] {
            if let own = expression.firstMatch(in: title.text, range: range), let found = Range(own.range, in: title.text) {
                return draft.withStartText(String(title.text[found]).trimmingCharacters(in: .whitespaces))
            }
        }
        // The columns are the same in every row, so any cell of the entry's column gives the span.
        guard let cell = cells.first(where: { $0.cellWidth > 0 && title.box.x >= Int($0.midX - $0.cellWidth / 2) - 2 && Double(title.box.x) < $0.midX + $0.cellWidth / 2 })
        else { return draft }
        let left = cell.midX - cell.cellWidth / 2, right = cell.midX + cell.cellWidth / 2
        let row = lines.filter { line in
            DateResolver.isClockLabel(line.text) && line.box.x > title.box.x && line.box.midX >= left && line.box.midX < right
                && abs(line.box.midY - title.box.midY) <= max(4, Double(title.box.height) * 0.6)
        }
        return draft.withStartText(row.min { $0.box.x < $1.box.x }?.text.trimmingCharacters(in: .whitespaces))
    }

    private static let leadingClock = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(?:\s?[ap]\.?m\.?)?(?=\s|$)"#, options: .caseInsensitive)
    private static let trailingClock = try! NSRegularExpression(pattern: #"\b\d{1,2}:\d{2}(?:\s?[ap]\.?m\.?)?$"#, options: .caseInsensitive)

    /// The most tokens the extract answer may have: about 20 per line shown, at least 3072, at most 16384, and 4096 more for a model that
    /// thinks (its thinking counts, and some models think whatever the setting says). A real answer is far shorter; a model that falls
    /// into a loop (a title that repeats the whole screen) ends here and fails, instead of running to the timeout.
    static func answerLimit(lines: Int, modelThinks: Bool) -> Int { min(16384, max(3072, 20 * lines) + (modelThinks ? 4096 : 0)) }

    /// A week view with a month picker beside it reads as a month view to the model. When date headers (a weekday name with its day
    /// number) run across the picture, much wider than any grid of day labels, the picture is a week view (or a day view).
    static func corrected(_ result: ClassificationResult, lines: [RecognisedLine], locales: [Locale], reference: Date, zone: TimeZone,
                          dayWithManyHeadersIsAWeek: Bool = false) -> ClassificationResult {
        // A window of a week view is often called a day view (spec 011): a day view has one header, so several headers across it are a week.
        if dayWithManyHeadersIsAWeek, result.kind == .calendarDay,
           DateResolver.headers(in: lines, locales: locales, reference: reference, timezone: zone).count >= 3 { return result.withKind(.calendarWeek) }
        guard result.kind == .calendarMonth else { return result }
        let headers = DateResolver.headers(in: lines, locales: locales, reference: reference, timezone: zone)
        guard headers.count >= 3, let left = headers.map(\.midX).min(), let right = headers.map(\.midX).max() else { return result }
        let cells = DateResolver.monthCells(in: lines, locales: locales, reference: reference, timezone: zone)
        let span = (cells.map(\.midX).max() ?? 0) - (cells.map(\.midX).min() ?? 0)
        return cells.isEmpty || right - left > span * 1.5 ? result.withKind(.calendarWeek) : result
    }

    /// True when the end is missing, unresolved, or not after the start.
    static func isNotAfter(_ end: ResolvedValue, _ start: ResolvedValue?) -> Bool {
        guard let date = end.date, let begins = start?.date else { return false }
        return date <= begins
    }

    /// The languages dates are read in, with the one the picture is written in first (`language` tag), when it is among them.
    static func locales(_ locales: [Locale], preferring language: String?) -> [Locale] {
        guard let language, let index = locales.firstIndex(where: { $0.language.languageCode?.identifier == language }), index > 0 else { return locales }
        return [locales[index]] + locales.enumerated().filter { $0.offset != index }.map(\.element)
    }

    /// The zone a context gives its dates: its own, else the Mac's. A stored zone that no longer exists is reported, not hidden.
    static func zone(for context: ContextRecord?, mac: TimeZone) -> (zone: TimeZone, source: String) {
        guard let identifier = context?.timezone else { return (mac, "mac") }
        if let zone = TimeZone(identifier: identifier) { return (zone, "context") }
        return (mac, "invalid-context-zone")
    }

    /// What the duration step needs from a calendar view: the picture and the width of one column of blocks.
    struct Geometry {
        let image: CGImage
        let columnWidth: Int
        /// Where `image` starts in the full picture: a window's cut is measured on its own, so the page colour is the window's and not the desktop's.
        var origin: (x: Int, y: Int) = (0, 0)

        /// The part of the full picture a window covers, for measuring its blocks.
        static func cut(of image: CGImage, frame: PixelBox, columnWidth: Int) -> Geometry {
            let x0 = max(0, frame.x), y0 = max(0, frame.y), x1 = min(image.width, frame.x + frame.width), y1 = min(image.height, frame.y + frame.height)
            guard x1 > x0, y1 > y0, let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
                return Geometry(image: image, columnWidth: columnWidth)
            }
            return Geometry(image: cropped, columnWidth: columnWidth, origin: (x0, y0))
        }
    }

    /// The median spacing of the date headers for a week, else a seventh of the picture; a day view has one column, the whole width.
    static func columnWidth(headers: [DateHeader], imageWidth: Int, kind: ScreenKind) -> Int {
        if kind == .calendarDay { return imageWidth }
        let gaps = zip(headers, headers.dropFirst()).map { $1.midX - $0.midX }.sorted()
        if !gaps.isEmpty { return max(1, Int(gaps[gaps.count / 2])) }
        return kind == .calendarWeek ? imageWidth / 7 : imageWidth
    }

    /// Turns a checked draft into a finding. Each date text is resolved by `DateResolver`; what it cannot settle stays as written.
    static func assemble(_ draft: FindingDraft, lines: [RecognisedLine], context base: ResolutionContext, geometry: Geometry? = nil,
                         tags: [CaptureTag] = [], windowKey: String? = nil) -> Finding {
        // An email's own date is the reference for the words in it.
        let context = ResolutionContext(captureTime: base.captureTime, timezone: base.timezone, headers: base.headers, lines: base.lines,
                                        dateOrder: base.dateOrder, locales: base.locales,
                                        sentReference: DateResolver.sentReference(for: draft, in: base), cells: base.cells, clock: base.clock)
        func resolve(_ field: String, _ texts: String?...) -> ResolvedValue {
            let text = texts.lazy.compactMap { $0 }.first ?? ""
            return DateResolver.resolve(text: text, field: field, draft: draft, in: context)
        }
        var results: [String: ResolvedValue] = [:]
        var endDropped = false
        switch draft.kind {
        case .appointment:
            results["start"] = resolve("start", draft.startText, draft.dateText)
            // An end is "read" only when the block's own text shows it (not the hour scale at the side) and it is after the start;
            // otherwise it is dropped and the end is worked out below, flagged inferred.
            let end = resolve("end", draft.endText)
            if draft.endText != nil, !Self.endIsShown(draft.endText, in: draft.citedLines, lines: lines) || Self.isNotAfter(end, results["start"]) {
                endDropped = true
                results["end"] = DateResolver.resolve(text: "", field: "end", draft: draft, in: context)
            } else {
                results["end"] = end
            }
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
        if draft.kind == .appointment, draft.endText == nil || endDropped, let start = results["start"], let begins = start.date, !start.allDay, draft.allDay != true {
            var minutes = 60, reason = "default-60"
            if let geometry, let title = Self.blockTitleLine(draft, lines: lines, headers: base.headers),
               let measured = BlockGeometry.duration(titleBox: PixelBox(x: title.box.x - geometry.origin.x, y: title.box.y - geometry.origin.y, width: title.box.width,
                                                                          height: title.box.height),
                                                  lines: lines, image: geometry.image, columnWidth: geometry.columnWidth) {
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
                       provenance: provenance, unresolved: unresolved, tags: tags, windowKey: windowKey)
    }
}
