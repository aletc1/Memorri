import MemorriCore

/// Stands in for the pipeline when the storage cannot be used; every request reports the reason.
struct UnavailableCaptureRunner: CaptureRunning {
    let reason: String
    func run(trigger: CaptureTrigger) async -> CaptureOutcome? { .failed(reason: reason) }
}
