# Core interfaces: hardening (spec 010)

```swift
// Cancellation
struct CalendarCoverage { imageID, windowKey, contextID?, kind, spans: [DateInterval] }
enum CoverageReader { static func coverage(window/picture: lines, headers, visible: [PixelBox], kind, zone, reference) -> CalendarCoverage? }   // nil = silence
struct CancellationDetector {
  func record(imageID: String) throws -> Int        // coverage + absences of a first analysis; returns items newly flagged
  func clearContradicted(imageID: String) throws    // after a re-read or a new sighting: drop absences it contradicts
}
ItemOperations.confirmStillHappening(_ id) -> OpID  // approve + cancel_cleared_at; undoable
// `Cancelled` is ItemOperations.dismiss

// Notifications
protocol NoticeShowing: Sendable { func show(_ notice: Notice) async }
actor NewItemsNotifier { init(database, quiet: Duration, ceiling: Duration, enabled: () -> Bool, shower: NoticeShowing)
  func itemsCreated(_ ids: [String])  func fire() async }
enum NotificationWords { static func text(new: Int, needReview: Int, cancelled: Int) -> String }   // "3 new items, 1 needs review"

// Backup
struct ItemExporter { func export(to url: URL) throws -> Int }                                   // JSON, atomic
struct LibraryBackup { func sizes() -> (withPictures: Int64, without: Int64)
  func make(to folder: URL, includePictures: Bool, progress: (Double) -> Void) async throws -> BackupManifest }  // cancellable, no partial package
struct LibraryRestore { func validate(_ package: URL) throws -> BackupManifest
  func stage(_ package: URL) throws }                                                            // writes restore-pending/
enum StorageBootstrap { static func finishStagedRestore(paths:) throws -> RestoreResult? }      // before the database opens; rolls back on failure
struct SafetyCopies { func list() -> [SafetyCopy]; func delete(_ name: String) throws }

// Login, diagnostics
protocol LoginItemControlling: Sendable { var status: LoginItemStatus {get}; func register() throws; func unregister() throws }
struct DiagnosticsReport { static func build(_ inputs: DiagnosticsInputs, log: [String], sensitive: Set<String>) -> DiagnosticsReport }
enum LogSanitiser { static func keep(_ line: String, category: String, sensitive: Set<String>) -> Bool }
```
