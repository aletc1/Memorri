import Foundation

/// The exact menu texts for the queue (contracts/ui-contract.md, FR-016). Pure.
/// Precedence: paused, then waiting for the server or model, then running, then waiting, then idle;
/// failures are appended.
public enum AnalysisLine {
    public static func text(for progress: QueueProgress) -> String {
        let counts = progress.counts
        let base: String
        if progress.paused {
            base = "Analysis paused"
        } else if let reason = progress.holdingReason, counts.waiting > 0 {
            base = "Analysis waiting: \(reason)"
        } else if counts.running > 0 {
            base = "Analysing 1 of \(counts.running + counts.waiting)…"
        } else if counts.waiting > 0 {
            base = "Analysis: \(counts.waiting) waiting"
        } else {
            base = "Analysis: idle"
        }
        return counts.failed > 0 ? "\(base), \(counts.failed) failed" : base
    }
}
