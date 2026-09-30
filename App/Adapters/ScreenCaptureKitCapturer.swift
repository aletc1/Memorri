import AppKit
import CoreGraphics
import MemorriCore
import ScreenCaptureKit
import os

/// Takes one picture of each distinct display with ScreenCaptureKit (ADR 0004): native pixel size,
/// no pointer, mirror sets counted once. Permission refusal is SCStreamError -3801 from either call
/// (spike S2).
struct ScreenCaptureKitCapturer: DisplayCapturing {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "capture")

    func captureAllDisplays() async throws -> DisplayCaptureResult {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw Self.failure(for: error)
        }

        let displays = content.displays.filter { CGDisplayMirrorsDisplay($0.displayID) == kCGNullDirectDisplay }
        guard !displays.isEmpty else { throw CaptureFailure.noDisplays }
        let names = await Self.displayNames()

        var captured: [CapturedDisplay] = []
        var firstError: Error?
        var failed = 0
        await withTaskGroup(of: Result<CapturedDisplay, Error>.self) { group in
            for display in displays {
                let name = names[display.displayID]
                let box = DisplayBox(display: display)
                let windows = Self.windows(on: display, in: content)
                group.addTask { await Self.capture(box.display, name: name, windows: windows) }
            }
            for await result in group {
                switch result {
                case .success(let display): captured.append(display)
                case .failure(let error):
                    failed += 1
                    firstError = firstError ?? error
                    Self.logger.error("display capture failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if captured.isEmpty, let firstError { throw Self.failure(for: firstError) }
        captured.sort { $0.displayID < $1.displayID }
        return DisplayCaptureResult(displays: captured, failedDisplayCount: failed)
    }

    /// `SCDisplay` is a read-only description of a display; ScreenCaptureKit uses it from any thread.
    private struct DisplayBox: @unchecked Sendable { let display: SCDisplay }

    private static func capture(_ display: SCDisplay, name: String?, windows: [WindowInfo]) async -> Result<CapturedDisplay, Error> {
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = Double(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((Double(filter.contentRect.width) * scale).rounded())
            configuration.height = Int((Double(filter.contentRect.height) * scale).rounded())
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return .success(CapturedDisplay(displayID: display.displayID, name: name, image: image, scale: scale, windows: windows))
        } catch {
            return .failure(error)
        }
    }

    /// Ordinary on-screen windows (layer 0) that overlap the display, frames converted from points on the desktop to pixels of
    /// the display's picture. Memorri's own windows are left out. Selection and clipping happen when the capture is stored.
    private static func windows(on display: SCDisplay, in content: SCShareableContent) -> [WindowInfo] {
        let scale = Double(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        let origin = display.frame.origin
        let ownBundle = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window in
            guard window.isOnScreen, window.windowLayer == 0, window.frame.intersects(display.frame),
                  window.owningApplication?.bundleIdentifier != ownBundle else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let frame = PixelBox(x: Int(((window.frame.minX - origin.x) * scale).rounded()),
                                 y: Int(((window.frame.minY - origin.y) * scale).rounded()),
                                 width: Int((window.frame.width * scale).rounded()),
                                 height: Int((window.frame.height * scale).rounded()))
            return WindowInfo(appName: window.owningApplication?.applicationName, bundleID: window.owningApplication?.bundleIdentifier,
                              title: (title?.isEmpty ?? true) ? nil : title, frame: frame)
        }
    }

    @MainActor
    private static func displayNames() -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    /// The message is localized, so the error is recognised by domain and code only.
    static func failure(for error: Error) -> CaptureFailure {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .other(nsError.localizedDescription)
    }
}
