# Core Interfaces: MemorriCore (spec 002)

Signatures only; bodies are written test-first. All types are `Sendable`. The spec 001 interfaces (`PermissionMonitor`, `CaptureRequestService`, `FeedbackPlaying`, `TimeSource`, `SettingsStore`) are extended where noted.

```swift
// MARK: Capturing displays (implemented by the ScreenCaptureKit adapter in the app)

public struct CapturedDisplay: Sendable {
    public let displayID: UInt32
    public let name: String?
    public let image: CGImage            // full native resolution, no pointer
    public let scale: Double
}

public enum CaptureFailure: Error, Sendable, Equatable {
    case permissionDenied
    case noDisplays
    case other(String)
}

public protocol DisplayCapturing: Sendable {
    /// One result per distinct display (mirror sets counted once). A display that fails is
    /// reported in `failures` and does not stop the others.
    func captureAllDisplays() async throws -> DisplayCaptureResult
}

public struct DisplayCaptureResult: Sendable {
    public let displays: [CapturedDisplay]
    public let failedDisplayCount: Int
}

// MARK: Encoding

public enum StorageQuality {
    public static let fullResolution: Double = 0.9     // named, can be raised later (FR-004)
    public static let analysisCopy: Double = 0.9
}

public struct EncodedPicture: Sendable { public let data: Data; public let width: Int; public let height: Int }

public protocol ImageEncoding: Sendable {
    func encodeFullResolution(_ image: CGImage) throws -> EncodedPicture          // HEIC
    func encodeAnalysisCopy(_ image: CGImage, longEdge: Int) throws -> EncodedPicture   // HEIC, never enlarged
}

// MARK: Free space

public protocol DiskSpaceChecking: Sendable {
    func freeBytes(at url: URL) throws -> Int64
}

// MARK: Outcome

public enum CaptureOutcome: Sendable, Equatable {
    case complete(displays: Int)
    case partial(captured: Int, of: Int)
    case failed(reason: String)
    case permissionDenied
}

public enum LastCaptureResult: Sendable, Equatable {
    case complete, partial(captured: Int, of: Int), failed(reason: String)
}

// MARK: Pipeline

public protocol CaptureRunning: Sendable {
    /// nil when another capture is already running (FR-011).
    func run(trigger: CaptureTrigger) async -> CaptureOutcome?
}

public actor CapturePipeline: CaptureRunning {
    public static let minimumFreeBytes: Int64 = 1_073_741_824          // FR-022
    public init(capturer: any DisplayCapturing, encoder: any ImageEncoding,
                disk: any DiskSpaceChecking, files: CaptureFileStore, store: any CaptureStoring,
                paths: AppPaths, settings: StorageSettings, time: any TimeSource = SystemTimeSource())
    public func run(trigger: CaptureTrigger) async -> CaptureOutcome?
}

// MARK: Storage

public struct AppPaths: Sendable {
    public let root: URL                                   // .../Application Support/Memorri
    public var database: URL { get }
    public var captures: URL { get }
    public var staging: URL { get }
    public init(root: URL)
    public func prepare() throws                           // create, mode 0700, exclude from backups
}

public final class StorageDatabase: Sendable {
    public enum OpenResult: Sendable {
        case opened(StorageDatabase)
        case openedAfterSettingAside(StorageDatabase, damagedFile: URL)   // FR-019
        case refusedNewerVersion                                          // FR-013
    }
    public static func open(paths: AppPaths) throws -> OpenResult
}

public struct CaptureEventRecord: Sendable, Equatable { /* columns of capture_events */ }
public struct CaptureImageRecord: Sendable, Equatable { /* columns of capture_images */ }

public protocol CaptureStoring: Sendable {      // lets tests fake a failing store
    func insert(event: CaptureEventRecord, images: [CaptureImageRecord]) throws
}

public struct CaptureStore: CaptureStoring {
    public init(database: StorageDatabase)
    public func insert(event: CaptureEventRecord, images: [CaptureImageRecord]) throws
    public func events(olderThan cutoff: Date?) throws -> [CaptureEventRecord]   // nil = all
    public func deleteEvents(ids: [String]) throws
    public func count() throws -> Int
    public func markMissing(imageID: String) throws
    public func allImages() throws -> [CaptureImageRecord]
}

public struct CaptureFileStore: Sendable {
    public init(paths: AppPaths)
    public func makeStagingDirectory() throws -> URL
    /// Renames the staging directory into captures/<yyyy-MM>/<eventID>/ and returns the final URL.
    public func commit(staging: URL, eventID: String, capturedAt: Date) throws -> URL
    public func discard(staging: URL)
    public func removeCaptureDirectory(eventID: String, capturedAt: Date)
    /// Start-up sweep: empties staging, removes directories without a record, flags records whose file is gone.
    @discardableResult
    public func reconcile(with store: CaptureStore) throws -> ReconcileReport
}

public struct StorageSummary: Sendable, Equatable {
    public let captureCount: Int
    public let pictureBytes: Int64
    public let databaseBytes: Int64
}
public struct ReconcileReport: Sendable, Equatable { public let stagingRemoved, orphansRemoved, markedMissing: Int }

public struct StorageStats: Sendable {
    public init(paths: AppPaths, store: CaptureStore)
    public func summary() throws -> StorageSummary         // reads the files themselves (SC-006)
}

public struct CleanupService: Sendable {
    public struct Preview: Sendable, Equatable { public let captureCount: Int; public let bytes: Int64 }
    public init(paths: AppPaths, store: CaptureStore, files: CaptureFileStore, time: any TimeSource = SystemTimeSource())
    public func preview(olderThanDays days: Int?, now: Date? = nil) throws -> Preview   // nil = all captures
    public func delete(olderThanDays days: Int?, now: Date? = nil) throws -> Int        // returns captures deleted
}

public enum RetentionPolicy: Sendable, Equatable {
    case forever, days(Int)
    public func isShorter(than other: RetentionPolicy) -> Bool     // FR-018
}

public struct StorageSettings: Sendable {
    public static let modelLongEdgeRange = 512...4096
    public static let defaultModelLongEdge = 2048
    public static let defaultRetention: RetentionPolicy = .days(7)
    public init(store: any SettingsStore)
    public var modelLongEdge: Int { get }
    public func setModelLongEdge(_ value: Int) -> Bool     // false and unchanged when out of range (FR-005)
    public var retention: RetentionPolicy { get }
    public func setRetention(_ policy: RetentionPolicy) -> Bool   // days 1...3650
}

public struct RetentionService: Sendable {
    public init(cleanup: CleanupService, settings: StorageSettings, store: any SettingsStore)
    public func apply(now: Date) throws -> Int             // remove captures older than the policy; returns count
    public func runNow(now: Date) throws -> Int            // apply and remember the time; used at start and after a change
    public func runIfDue(now: Date) throws -> Int          // runNow unless it ran in the last 24 h
    public func removalPreview(for policy: RetentionPolicy, now: Date) throws -> CleanupService.Preview   // FR-018
}

// MARK: Start-up

public struct StorageContext: Sendable {
    public let paths: AppPaths
    public let store: CaptureStore?                        // nil when the database cannot be used
    public let files: CaptureFileStore
    public let notice: StartupNotice?                      // damaged file set aside (FR-019)
    public let capturingDisabledReason: String?            // database from a newer version (FR-013)
    public let reconcile: ReconcileReport?
}
public enum StartupNotice: Sendable, Equatable { case damagedDatabaseSetAside(fileName: String) }
public enum StorageBootstrap {
    /// Prepare paths, open the database, reconcile leftovers (FR-014).
    public static func start(paths: AppPaths) throws -> StorageContext
}

// MARK: Extensions to spec 001

extension PermissionMonitor {
    /// A capture succeeded: the permission is granted, from any state (FR-010).
    public func captureSucceeded()
    /// A capture was refused for lack of permission: not granted, from any state (FR-007).
    public func captureDeniedByPermission()
}

public protocol FeedbackPlaying {     // adds the warning pair (FR-006, FR-008, FR-009)
    func flashWarning() async
    func playWarningSound() async
}

extension CaptureRequestService {
    /// init gains `runner: any CaptureRunning` and `onOutcome`; `request` returns the
    /// `CaptureOutcome?` (nil when dropped as a double press or ignored because one is running),
    /// plays feedback from it and reports the permission to `PermissionMonitor`.
}

// MARK: Additions made while building

public protocol SettingsStore: Sendable {      // gains int, string and date accessors
    func int(forKey: String) -> Int?;    func setInt(_: Int, forKey: String)
    func string(forKey: String) -> String?; func setString(_: String, forKey: String)
    func date(forKey: String) -> Date?;  func setDate(_: Date, forKey: String)
}

public enum LastCaptureLine {                  // exact menu texts, independent of the system language
    public static func text(for result: LastCaptureResult?, age seconds: TimeInterval) -> String
    public static func age(_ seconds: TimeInterval) -> String
}
```

## Behaviour the tests pin down

- `run` returns `nil` and does nothing when another run is in progress.
- With less than 1 GiB free, `run` takes no pictures and returns `.failed("Not enough free disk space")`; the event is recorded as failed.
- Each distinct display gives exactly one full and one analysis picture; the analysis copy's longer side equals `min(longEdge, original)`, aspect ratio kept, never enlarged.
- A `permissionDenied` failure stores no pictures, records a failed event and returns `.permissionDenied`; `CaptureRequestService` then calls `captureDeniedByPermission()` (the pipeline has no `PermissionMonitor`) and opens onboarding. `complete` and `partial` outcomes make the service call `captureSucceeded()`.
- `run` re-creates the data folders at its start, so a deleted folder does not break the next capture.
- A failing encoder records a `failed` event (reason `could not save the pictures`); a failing store records nothing.
- Some displays failing gives `.partial(captured:of:)`; the working displays' pictures are kept.
- A failure while writing or while inserting leaves no directory in `staging/` or `captures/` and no record.
- `reconcile` empties `staging/`, removes directories without a record, and marks records whose file is missing.
- `delete` and retention remove rows and directories together, never touch events newer than the cutoff, and never touch anything outside `captures/` and the two tables.
- `StorageSettings` rejects a size outside 512 to 4096 and a retention of 0 days or more than 3650, keeping the previous value.
- Feedback: `complete` plays the success pair (if enabled), `partial` and `failed` play the warning pair (same two switches), `permissionDenied` plays nothing and opens onboarding.
