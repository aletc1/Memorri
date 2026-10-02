# Core interfaces: reprocessing (spec 008)

```swift
public struct TrialStore                 // trials, trial_images, trial_findings, differences
  func create(model:, promptVersion:, think:) throws -> TrialRecord      // queues one job per stored capture with a kept picture (priority 1)
  func cancel(_ id), resume(_ id), delete(_ id)
  func all() -> [TrialRecord]; func progress(_ id) -> TrialProgress; func observe() -> AsyncStream<[TrialRecord]>
  func outOfDateCount(model:, promptVersions:) -> Int                    // FR-013
public struct TrialJobRunner: JobRunning                                  // kind "trial"; read, store proposals, stop
public enum TrialComparison
  static func compare(trial:, database:, reconciler:) async throws -> TrialReport   // totals + [TrialDifference]; dry run
  static func compare(_ a: trial, with b: trial, ...) async throws -> TrialReport
public struct TrialReport { totals: TrialTotals; differences: [TrialDifference] }
public struct TrialDifference { id, kind(.new/.changed/.notFound), imageID, itemID?, fields: [FieldChange], protected: ProtectedReason?, state }
public struct TrialApplier
  func apply(trial:, differences ids: [String]) async throws -> TrialApplyResult   // one op `apply_trial`; skipped with reasons
ItemOperations.undo handles OperationKind.applyTrial
```
Pure parts (classification, protection, totals, words) are in `TrialComparison` and `TrialWords` and tested without UI.
