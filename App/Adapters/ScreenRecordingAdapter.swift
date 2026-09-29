import AppKit
import CoreGraphics
import MemorriCore

/// Talks to macOS about the Screen Recording permission. Never captures screen content.
struct ScreenRecordingAdapter: ScreenRecordingChecking {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// `CGPreflightScreenCaptureAccess` reads the current state without prompting.
    func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (once) and adds the app to the Screen Recording list.
    /// Without this call the app may only be listed under "system audio only" (spike R5).
    @discardableResult
    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    // MARK: Asking a fresh copy of the app

    static let probeArgument = "--probe-permission"

    /// A running process keeps the permission answer it had at launch, so a grant or revocation
    /// made in System Settings is invisible to it. A freshly started copy of the same app sees it
    /// at once. This runs one and returns what it reported, or `nil` if it could not be run or
    /// did not answer within `probeTimeout` (so a hung probe cannot stall the polling loop).
    func isGrantedInFreshProcess() async -> Bool? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = [Self.probeArgument]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            let answer = OneShot(continuation)
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                answer.finish(String(decoding: data, as: UTF8.self).contains("granted"))
            }
            do { try process.run() } catch {
                answer.finish(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.probeTimeout) {
                if process.isRunning { process.terminate() }
                answer.finish(nil)
            }
        }
    }

    static let probeTimeout: TimeInterval = 2

    /// Resumes a continuation exactly once, whichever of the answer or the timeout comes first.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool?, Never>?

        init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

        func finish(_ value: Bool?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Probe mode: print the permission state and quit at once, before any UI or single-instance
    /// check. Called first thing at launch.
    static func runProbeIfRequested() {
        guard CommandLine.arguments.contains(probeArgument) else { return }
        print(CGPreflightScreenCaptureAccess() ? "granted" : "denied")
        fflush(stdout)
        exit(0)
    }
}

