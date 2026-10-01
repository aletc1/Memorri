import Foundation

/// Sends each job to the runner registered for its `kind` (`test`, `analyse`, `analyse-force`). A kind
/// nobody handles fails at once, so a job from a newer version cannot loop through retries.
public struct CompositeJobRunner: AnalysisJobRunning {
    private let runners: [String: any AnalysisJobRunning]

    public init(runners: [String: any AnalysisJobRunning]) {
        self.runners = runners
    }

    public func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        guard let runner = runners[job.kind] else { return .permanent("unknown job kind") }
        return await runner.run(job, attempt: attempt)
    }
}
