import MemorriCore

/// Stands in for the pipeline when the storage cannot be used; every request reports the reason.
struct UnavailableCaptureRunner: CaptureRunning, WindowCaptureRunning {
    let reason: String
    func run(trigger: CaptureTrigger) async -> CaptureOutcome? { .failed(reason: reason) }
    func runWindow(trigger: CaptureTrigger) async -> CaptureOutcome? { .failed(reason: reason) }
}
