# Core Interfaces: MemorriCore (spec 004)

Signatures only; bodies are written test-first. All types are `Sendable`. Types from specs 002 and 003 (`CaptureStore`, `AnalysisQueue`, `AnalysisJobStoring`, `OllamaClient`, `SchemaValidator`, `JSONValue`, `ThinkWireValue`, `TimeSource`) are used as they are.

```swift
// MARK: Recognition (Recognition/)

public struct RecognisedLine: Sendable, Equatable {
    public let n: Int                       // 1...count, reading order
    public let text: String
    public let box: PixelBox                // top-left origin, pixels of the full-resolution picture
    public let confidence: Double
}
public struct PixelBox: Sendable, Equatable, Codable { public let x, y, width, height: Int
    public var midX: Double { get }; public var midY: Double { get } }

public protocol TextRecogniser: Sendable {
    /// Reads every line; an empty array is a valid answer.
    func recognise(_ image: CGImage) async throws -> [RecognisedLine]
}
public struct VisionTextRecogniser: TextRecogniser {     // RecognizeTextRequest, accurate, language correction per spike S1
    public init(usesLanguageCorrection: Bool = true)
    public static let descriptor: String                  // stored in ocr_reads.recogniser
}
public enum ReadingOrder {
    /// Rows by top edge with half the median line height as tolerance, then left to right.
    public static func sort(_ boxes: [(text: String, box: PixelBox, confidence: Double)]) -> [RecognisedLine]
}
public struct OCRStore: Sendable {
    public init(database: StorageDatabase)
    public func save(imageID: String, lines: [RecognisedLine], durationMs: Int, recogniser: String, at: Date) throws   // idempotent
    public func isRead(imageID: String) throws -> Bool
    public func lines(imageID: String) throws -> [RecognisedLine]
}

// MARK: Screen kinds, prompts, schemas (Extraction/)

public enum ScreenKind: String, Sendable, CaseIterable { case calendarMonth = "calendar_month", calendarWeek = "calendar_week",
    calendarDay = "calendar_day", email, chat, document, other }

public enum ExtractionPrompts {
    public static let classifyVersion = "classify-v1"
    public static func classifyPrompt() -> String
    public static func version(for kind: ScreenKind) -> String                    // "extract-<kind>-v1"
    /// Lines are given as `L<n> (x%,y%) text`, capped (see research R4).
    public static func extractPrompt(kind: ScreenKind, lines: [RecognisedLine], pictureSize: (Int, Int)) -> (prompt: String, capApplied: Bool)
}
public enum ExtractionSchemas {
    public static let classifySchema: JSONValue
    public static func schemaVersion(for kind: ScreenKind) -> String              // "schema-<kind>-v1"
    public static func extractSchema(for kind: ScreenKind) -> JSONValue
}

// MARK: Model access used by the pipeline (Analysis/ModelStep.swift)

public protocol ModelChatting: Sendable {
    func chat(_ request: ChatRequest) async throws -> ChatResponse          // OllamaClient conforms
}
public struct ModelStepSettings: Sendable, Equatable {                      // read once per attempt
    public let model: String, think: ThinkSetting, timeout: TimeInterval, modelThinks: Bool
}

// MARK: Findings (Extraction/Findings.swift)

public enum FindingKind: String, Sendable { case appointment, task, reminder, deadline }
public enum FieldOrigin: String, Sendable, Codable { case read, inferred }
public struct FieldProvenance: Sendable, Codable, Equatable { public let origin: FieldOrigin; public let rule: String; public let reason: String? }

public struct FindingDraft: Sendable, Equatable {       // the model's answer, literal texts
    public let kind: FindingKind; public let title: String; public let citedLines: [Int]
    public let startText, endText, dateText, dueText, remindText: String?
    public let allDay: Bool?; public let people: [String]; public let place, notes: String?
    public let columnLine: Int?; public let sentText: String?; public let messageTimeText: String?
}
public struct Finding: Sendable, Equatable {            // checked and resolved
    public let id: String; public let kind: FindingKind; public let title: String
    public let allDay: Bool; public let start, end, due, remind: Date?; public let timezone: String
    public let people: [String]; public let place, notes: String?
    public let citedLines: [Int]; public let confidence: Double
    public let provenance: [String: FieldProvenance]; public let unresolved: [String: String]
}
public enum CitationCheck {
    public struct Discard: Sendable, Equatable, Codable { public let title: String; public let reason: String; public let citedLines: [Int] }
    /// Keeps drafts that cite at least one line and only existing lines; the others become discards.
    public static func apply(_ drafts: [FindingDraft], lineCount: Int) -> (kept: [FindingDraft], discarded: [Discard])
}

// MARK: Dates (Extraction/DateParser.swift, DateResolver.swift)

public struct ParsedDate: Sendable, Equatable { /* weekday, day, month, year, hour, minute, meridiem, relative */ }
public enum DateParser {
    public static func parse(_ text: String, locales: [Locale]) -> ParsedDate?
    public static func dateOrder(ofUnambiguous texts: [String]) -> DateOrder?      // dmy, mdy, ymd
}
public struct DateHeader: Sendable, Equatable { public let line: Int; public let midX: Double; public let date: DateComponents }
public struct ResolutionContext: Sendable {
    public let captureTime: Date; public let timezone: TimeZone; public let headers: [DateHeader]
    public let lines: [RecognisedLine]; public let dateOrder: DateOrder?; public let locales: [Locale]; public let sentReference: Date?
}
public struct ResolvedValue: Sendable, Equatable { public let date: Date?; public let allDay: Bool; public let provenance: FieldProvenance; public let unresolvedText: String? }
public enum DateResolver {
    /// Rules in order: explicit-date, header-column, relative-day, end-of-week, weekday-only, time-only, unresolved.
    public static func resolve(text: String, field: String, draft: FindingDraft, in context: ResolutionContext) -> ResolvedValue
    public static func headers(in lines: [RecognisedLine], locales: [Locale], referenceYear: Int) -> [DateHeader]
}

// MARK: Durations (Extraction/BlockGeometry.swift)

public struct HourScale: Sendable, Equatable { public let pixelsPerHour: Double; public func minutes(forPixels: Double) -> Double }
public enum BlockGeometry {
    /// nil with fewer than two clock labels in one narrow column.
    public static func hourScale(lines: [RecognisedLine]) -> HourScale?
    /// Vertical extent in pixels of the coloured block around `titleBox`, or nil when it is not clearly a block.
    public static func blockHeight(around titleBox: PixelBox, in image: CGImage, columnWidth: Int) -> Int?
    /// Minutes rounded to 15, limited to 30...720, or nil.
    public static func duration(titleBox: PixelBox, lines: [RecognisedLine], image: CGImage, columnWidth: Int) -> Int?
}

// MARK: Tags and contexts (Extraction/TagExtractor.swift, ContextMatcher.swift, Contexts/)

public struct CaptureTag: Sendable, Equatable, Codable { public let key: String; public let value: String; public let confidence: Double; public let source: String }
public struct WindowInfo: Sendable, Equatable { public let appName, bundleID, title: String?; public let frame: PixelBox }
public enum TagExtractor {
    public static func fromCapture(displaySize: (Int, Int), scale: Double, windows: [WindowInfo]) -> [CaptureTag]
    public static func fromLines(_ lines: [RecognisedLine]) -> [CaptureTag]          // language, clock_style, date_order, account, domain, timezone_label
    public static func fromClassification(_ c: ClassificationResult) -> [CaptureTag]  // visual, low confidence marked
}
public struct ContextRecord: Sendable, Equatable { public let id: String; public var name: String; public var timezone: String?; public var hints: [ContextHint] }
public struct ContextHint: Sendable, Equatable { public enum Kind: String, Sendable { case windowTitle = "window_title", app, domain, keyword }; public let kind: Kind; public let value: String }
public struct ContextDecision: Sendable, Equatable { public enum Source: String, Sendable { case auto, user, none }
    public let contextID: String?; public let source: Source; public let score: Double
    public let matched: [MatchedHint]; public let runnerUp: RunnerUp? }
public enum ContextMatcher {
    public static func decide(contexts: [ContextRecord], windows: [WindowInfo], tags: [CaptureTag], lines: [RecognisedLine]) -> ContextDecision
    // windowTitle 3, app 3, domain 2.5, keyword 1; needs >= 2 points and a lead of >= 1; a tie is recorded
}
public struct ContextStore: Sendable {
    public init(database: StorageDatabase)
    public func all() throws -> [ContextRecord]
    public func add(name: String, timezone: String?, hints: [ContextHint]) throws -> ContextRecord
    public func update(_ context: ContextRecord) throws
    public func delete(id: String) throws
    public func setUserChoice(imageID: String, contextID: String?, at: Date) throws     // source = user
    public func decision(imageID: String) throws -> ContextDecision?
}

// MARK: The one entry point (Extraction/AnalysisPipeline.swift)

public struct PipelineInput: Sendable {
    public let image: CGImage                    // full resolution
    public let analysisJPEG: Data                // the copy sent to the model, already converted
    public let analysisSize: (width: Int, height: Int)
    public let captureTime: Date
    public let displaySize: (Int, Int); public let scale: Double
    public let windows: [WindowInfo]
    public let contexts: [ContextRecord]
    public let userContextID: String?            // a user choice wins
    public let macTimezone: TimeZone
    public let reuse: Reuse                      // stored lines and classification for a resumed job
    public struct Reuse: Sendable { public var lines: [RecognisedLine]?; public var classification: ClassificationResult? }
}
public struct AnalysisResult: Sendable {
    public let lines: [RecognisedLine]; public let classification: ClassificationResult
    public let tags: [CaptureTag]; public let findings: [Finding]; public let discards: [CitationCheck.Discard]
    public let decision: ContextDecision; public let timezone: TimeZone; public let timezoneSource: String
    public let lineCapApplied: Bool; public let steps: [StepRecord]        // what was run and its raw answers
}
public struct StepRecord: Sendable { public let step: String; public let request: String; public let rawAnswer: String?; public let durationMs: Int; public let failure: String? }

public enum PipelineError: Error, Sendable, Equatable { case transient(String), permanent(String), serverUnavailable }

public struct AnalysisPipeline: Sendable {
    public init(recogniser: any TextRecogniser, model: any ModelChatting, time: any TimeSource)
    public func analyse(_ input: PipelineInput, settings: ModelStepSettings) async throws -> AnalysisResult   // throws PipelineError
}

// MARK: Storing, jobs and the queue (Analysis/)

public protocol AnalysisEnqueuing: Sendable { func enqueueAnalysis(imageIDs: [String]) async }   // AnalysisQueue conforms
public struct AnalysisResultStore: Sendable {
    public init(database: StorageDatabase)
    public func save(_ result: AnalysisResult, imageID: String, runID: String?, at: Date) throws    // one transaction, replaces earlier analysis
    public func analysis(imageID: String) throws -> StoredAnalysis?
    public func findings(imageID: String) throws -> [Finding]
    public func tags(imageID: String) throws -> [CaptureTag]
    public func unanalysedImageIDs() throws -> [String]     // no analysis and no waiting or running job
}
public struct ImageAnalysisJobRunner: AnalysisJobRunning {    // kinds "analyse" and "analyse-force"
    public init(service: OllamaService, pipeline: AnalysisPipeline, pictures: any AnalysisPictureProviding,
                fullPictures: any FullPictureProviding, captures: CaptureStore, ocr: OCRStore, results: AnalysisResultStore,
                contexts: ContextStore, jobs: any AnalysisJobStoring, settings: OllamaSettings, time: any TimeSource)
}
public protocol FullPictureProviding: Sendable { func fullPicture(imageID: String) throws -> CGImage? }
public struct CompositeJobRunner: AnalysisJobRunning { public init(runners: [String: any AnalysisJobRunning]) }   // by job kind

public struct AnalysisSettings: Sendable { public init(store: any SettingsStore); public var automatic: Bool { get }; public func setAutomatic(_ value: Bool) }
```

`AnalysisQueue` gains `enqueue(kind: String, imageID: String?)` (the existing `enqueueTest` stays) and conforms to `AnalysisEnqueuing`. `CapturePipeline` gains an optional `enqueuer` and calls it with the stored picture ids when `AnalysisSettings.automatic` is on. `CapturedDisplay` gains `windows: [WindowInfo]`, and `CaptureStoring` gains the windows to write.

## Behaviour the tests pin down

- `ReadingOrder` gives the same numbers for the same lines shuffled; two lines on one row sort left to right; `OCRStore.save` twice leaves one set of lines; zero lines is "read".
- `CitationCheck` drops findings with no citation or a line number outside `1...lineCount` and keeps the rest.
- `DateResolver`: table of at least 40 cases covering every rule, English and Spanish names, 12 and 24 hour times, year rollover, a capture at 00:10 in a zone whose date differs from the Mac's, headers for a week view, ambiguous numeric order, and unresolved text kept as written.
- `BlockGeometry`: drawn blocks of 30, 60, 90 and 120 minutes give the right minutes; a picture with no hour labels gives nil; a block wider than a column gives nil.
- `TagExtractor`, `ContextMatcher`: table-driven; a tie gives `none` with both contexts recorded; a user choice is never replaced.
- `AnalysisPipeline` with fakes: a full run gives kind, tags, resolved findings and a decision; a finding with a bad citation is discarded and recorded; an answer that fails the schema throws `transient`; a resumed run with stored lines and classification makes exactly one model call; an unreachable server throws `serverUnavailable`.
- `ImageAnalysisJobRunner`: maps pipeline errors to `JobOutcome` as in spec 003; writes one run per model call with the right `step`; a second run of the same picture leaves one set of findings; the user's context choice survives `analyse-force`; a deleted capture gives `permanent("picture no longer stored")`.
- Deleting a capture removes its lines, windows, tags, analysis, context row and findings, and leaves contexts and other captures alone.
