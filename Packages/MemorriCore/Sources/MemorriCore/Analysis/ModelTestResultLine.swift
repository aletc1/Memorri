import Foundation

/// The result line under **Test the model** (contracts/ui-contract.md). Pure.
public enum ModelTestResultLine {
    public static let sampleLength = 60

    /// nil while the job has not finished or failed.
    public static func text(job: AnalysisJobRecord, run: ModelRunRecord?) -> String? {
        switch job.state {
        case AnalysisJobRecord.State.finished.rawValue:
            guard let run else { return "Answer valid" }
            let seconds = String(format: "%.1f", Double(run.durationMs) / 1000)
            return "Answer valid in \(seconds) s: \"\(sample(of: run.rawAnswer))\""
        case AnalysisJobRecord.State.failed.rawValue:
            return "Failed: \(job.failureReason ?? "unknown reason")"
        default:
            return nil
        }
    }

    /// The first 60 characters of the answer's `description`.
    static func sample(of answer: String?) -> String {
        let json = answer?.components(separatedBy: ModelTestJob.thinkingMarker).first
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = value, case .string(let description)? = fields["description"] else { return "" }
        let collapsed = description.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count > sampleLength ? String(collapsed.prefix(sampleLength)) + "…" : collapsed
    }
}
