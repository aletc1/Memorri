import AppKit
import MemorriCore
import SwiftUI
import os

enum WindowID: String, CaseIterable {
    case settings, onboarding, inbox, search

    var title: String {
        switch self {
        case .settings: "Memorri Settings"
        case .onboarding: "Screen Recording Access"
        case .inbox: "Inbox"
        case .search: "Search"
        }
    }

    var contentSize: NSSize {
        switch self {
        case .settings: NSSize(width: 680, height: 600)
        case .onboarding: NSSize(width: 460, height: 340)
        case .inbox, .search: NSSize(width: 420, height: 220)
        }
    }
}

/// Owns one window per `WindowID`. Showing a window that already exists brings it to the front,
/// so there is never a second copy. Works from anywhere (hotkey, second launch, menu) because it
/// does not depend on a SwiftUI view being on screen.
@MainActor
final class WindowCoordinator {
    /// Supplies the SwiftUI content for a window the first time it is shown.
    var contentProvider: (WindowID) -> AnyView = { _ in AnyView(EmptyView()) }

    private var windows: [WindowID: NSWindow] = [:]

    func show(_ id: WindowID) {
        let window = windows[id] ?? makeWindow(for: id)
        windows[id] = window
        if !window.isVisible { position(window) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An agent app is rarely active, and macOS may refuse to activate it when the request does
        // not come from a click (for example a second launch). This shows the window regardless.
        window.orderFrontRegardless()
        Logger(subsystem: MemorriCore.subsystem, category: "windows")
            .notice("show \(id.rawValue, privacy: .public) visible=\(window.isVisible, privacy: .public) onScreen=\(window.occlusionState.contains(.visible), privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
    }

    func isVisible(_ id: WindowID) -> Bool {
        windows[id]?.isVisible ?? false
    }

    var anyWindowVisible: Bool {
        windows.values.contains { $0.isVisible }
    }

    private func makeWindow(for id: WindowID) -> NSWindow {
        let controller = NSHostingController(rootView: contentProvider(id))
        let window = NSWindow(contentViewController: controller)
        window.title = id.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(id.contentSize)
        return window
    }

    /// Centers the window on the display that holds the pointer.
    private func position(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }
}
