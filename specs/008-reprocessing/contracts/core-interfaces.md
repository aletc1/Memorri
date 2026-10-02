# Core interfaces: reprocessing (spec 008)

```swift
public struct TrialStore                 // trials, trial_images, trial_findings
  func create(model:, promptVersion:, think:, now:) throws -> TrialRecord  // a trial job per kept capture (priority 1); the others recorded skipped
  func cancel(_ id, now:), resume(_ id, now:), delete(_ id)
  func trial(id:), all(), observe() -> AsyncStream<[TrialRecord]>
  func readImageIDs(trialID:), findings(trialID:imageID:), state(trialID:imageID:)
  func saveProposal(...), mark(...)                                         // used by the job
  func eligibleCount(), outOfDateCount(model:, currentPromptVersions:)      // FR-013
  func captureInfo(imageIDs:), history() -> [TrialHistoryEntry]             // headings and the audit trail
public struct TrialJobRunner: AnalysisJobRunning                            // kind "trial": stored OCR, the user's contexts, the trial's model; stops after the pipeline
public struct TrialComparison
  func report(trialID:) async throws -> TrialReport                         // totals + [TrialDifference]; dry run of Reconciler.plan(imageID:findings:)
  func between(_ first: String, _ second: String) throws -> [TrialPairDifference]
public struct TrialApplier
  func apply(trialID:, differenceIDs:) async throws -> TrialApplyResult     // one operation `apply_trial`; skipped with reasons
ItemOperations.undo handles OperationKind.applyTrial (and makes the cut-outs again through its evidence writer)
TrialWords                                                                  // the words of the section
```
