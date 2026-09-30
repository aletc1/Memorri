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

public actor CapturePipeline {
    public static let minimumFreeBytes: Int64 = 1_073_741_824          // FR-022
    public init(capturer: any DisplayCapturing, encoder: any ImageEncoding,
                disk: any DiskSpaceChecking, files: CaptureFileStore, store: CaptureStore,
                settings: StorageSettings, time: any TimeSource)
    /// nil when another capture is already running (FR-011).
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

public struct CaptureStore: Sendable {
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
    public func reconcile(with store: CaptureStore) throws
}

public struct StorageSummary: Sendable, Equatable {
    public let captureCount: Int
    public let pictureBytes: Int64
    public let databaseBytes: Int64
}
public struct StorageStats: Sendable {
    public func summary() throws -> StorageSummary         // reads the files themselves (SC-006)
}

public struct CleanupService: Sendable {
    public struct Preview: Sendable, Equatable { public let captureCount: Int; public let bytes: Int64 }
    public func preview(olderThanDays days: Int?) throws -> Preview        // nil = all captures
    public func delete(olderThanDays days: Int?) throws -> Int             // returns captures deleted
}

public enum RetentionPolicy: Sendable, Equatable { case forever, days(Int) }

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
    public func runIfDue(now: Date) throws -> Int          // at start and about daily; returns captures removed
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
    /// init gains the pipeline; `request` returns the outcome and plays feedback from it.
}
```

## Behaviour the tests pin down

- `run` returns `nil` and does nothing when another run is in progress.
- With less than 1 GiB free, `run` takes no pictures and returns `.failed("Not enough free disk space")`; the event is recorded as failed.
- Each distinct display gives exactly one full and one analysis picture; the analysis copy's longer side equals `min(longEdge, original)`, aspect ratio kept, never enlarged.
- A `permissionDenied` failure stores no pictures, records a failed event, calls `captureDeniedByPermission()` and returns `.permissionDenied`.
- Some displays failing gives `.partial(captured:of:)`; the working displays' pictures are kept.
- A failure while writing or while inserting leaves no directory in `staging/` or `captures/` and no record.
- `reconcile` empties `staging/`, removes directories without a record, and marks records whose file is missing.
- `delete` and retention remove rows and directories together, never touch events newer than the cutoff, and never touch anything outside `captures/` and the two tables.
- `StorageSettings` rejects a size outside 512 to 4096 and a retention of 0 days or more than 3650, keeping the previous value.
- Feedback: `complete` plays the success pair (if enabled), `partial` and `failed` play the warning pair (same two switches), `permissionDenied` plays nothing and opens onboarding.
