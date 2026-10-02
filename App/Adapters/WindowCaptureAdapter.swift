import AppKit
import CoreGraphics
import MemorriCore
import ScreenCaptureKit
import os

/// Takes the one picture of a window capture (spec 013, research R2 and R3): the window in front of the frontmost application, as the screen shows
/// it inside the window's outline (so anything drawn over the window is in the picture and what is covered is not recovered). A window on one
/// display is taken with a display filter that leaves out Memorri's own windows; a window across displays is taken as a rectangle of the desktop.
/// Window names are returned to the pipeline and are never logged.
struct WindowCaptureAdapter: WindowCapturing {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "capture")

    func captureActiveWindow() async throws -> WindowCaptureResult {
        let content: SCShareableContent
        do { content = try await SCShareableContent.current } catch { throw Self.failure(for: error) }

        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let chosen: WindowCandidate
        let screens = content.displays.map { DesktopRect($0.frame) }
        switch ActiveWindowPicker.pick(candidates: Self.candidates(in: content), frontmostProcessID: frontmost,
                                       ownProcessID: ProcessInfo.processInfo.processIdentifier, screens: screens) {
        case .window(let candidate): chosen = candidate
        case .none: throw WindowCaptureFailure.noWindow
        case .ownWindow: throw WindowCaptureFailure.ownWindow
        }

        // The parts of the window on each display (a mirror set counts once); what is off every screen is not recorded.
        let displays = content.displays.filter { CGDisplayMirrorsDisplay($0.displayID) == kCGNullDirectDisplay }
        let pieces: [(display: DisplayBox, rect: DesktopRect)] = displays.compactMap { display in
            DesktopRect(display.frame).intersection(chosen.frame).map { (DisplayBox(display: display), $0) }
        }
        guard !pieces.isEmpty else { throw WindowCaptureFailure.other("the window is not on a screen") }
        let left = pieces.map(\.rect.x).min()!, top = pieces.map(\.rect.y).min()!
        let right = pieces.map(\.rect.maxX).max()!, bottom = pieces.map(\.rect.maxY).max()!
        let frame = DesktopRect(x: left, y: top, width: right - left, height: bottom - top)
        let main = pieces.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }!.display.display

        let image: CGImage
        let scale: Double
        let started = ContinuousClock.now
        do {
            if pieces.count == 1 {
                let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: main, excludingWindows: own)
                scale = Double(filter.pointPixelScale)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(x: frame.x - main.frame.origin.x, y: frame.y - main.frame.origin.y, width: frame.width, height: frame.height)
                configuration.width = max(1, Int((frame.width * scale).rounded()))
                configuration.height = max(1, Int((frame.height * scale).rounded()))
                configuration.showsCursor = false
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } else {
                image = try await SCScreenshotManager.captureImage(in: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
                scale = Double(image.width) / frame.width
            }
        } catch {
            throw Self.failure(for: error)
        }
        let milliseconds = (ContinuousClock.now - started).components.seconds * 1000
        Self.logger.notice("window picture taken displays=\(pieces.count) pixels=\(image.width)x\(image.height) ms=\(milliseconds)")

        let name = await Self.displayNames()[main.displayID]
        return WindowCaptureResult(image: image, scale: scale, displayID: main.displayID, displayName: name, frame: frame,
                                   appName: chosen.appName, bundleID: chosen.bundleID, title: chosen.title)
    }

    /// `SCDisplay` is a read-only description of a display; ScreenCaptureKit uses it from any thread.
    private struct DisplayBox: @unchecked Sendable { let display: SCDisplay }

    /// Every window the system lists, front to back as it orders on-screen windows (windows it does not list come last), with the transparency the
    /// system reports for each.
    private static func candidates(in content: SCShareableContent) -> [WindowCandidate] {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var rank: [CGWindowID: Int] = [:], alpha: [CGWindowID: Double] = [:]
        for (index, entry) in listed.enumerated() {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID, rank[id] == nil else { continue }
            rank[id] = index
            alpha[id] = entry[kCGWindowAlpha as String] as? Double ?? 1
        }
        return content.windows.sorted { (rank[$0.windowID] ?? Int.max) < (rank[$1.windowID] ?? Int.max) }.map { window in
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowCandidate(windowID: window.windowID, processID: window.owningApplication?.processID ?? -1, layer: window.windowLayer,
                                   isOnScreen: window.isOnScreen, frame: DesktopRect(window.frame), alpha: alpha[window.windowID] ?? 1,
                                   appName: window.owningApplication?.applicationName, bundleID: window.owningApplication?.bundleIdentifier,
                                   title: (title?.isEmpty ?? true) ? nil : title)
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

    /// The message is localized, so the error is recognised by domain and code only (as for the display capture).
    static func failure(for error: Error) -> WindowCaptureFailure {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue { return .permissionDenied }
        return .other(nsError.localizedDescription)
    }
}

extension DesktopRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}
