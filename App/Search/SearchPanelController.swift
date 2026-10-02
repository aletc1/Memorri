import AppKit
import MemorriCore
import SwiftUI

/// A panel that can take the keyboard without making Memorri the active app, so it floats over whatever the user is working in.
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating quick-search panel (spec 007, research R9): opens centred on the display with the pointer, closes on Escape, on losing
/// focus and after a result is opened.
@MainActor
final class SearchPanelController {
    private let environment: AppEnvironment
    private let model: SearchViewModel
    private var panel: SearchPanel?
    private var resignObserver: NSObjectProtocol?

    init(environment: AppEnvironment) {
        self.environment = environment
        model = SearchViewModel(environment: environment)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { position(panel) }
        model.open()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        model.close()
        panel?.orderOut(nil)
    }

    private func open(_ target: SearchPanelModel.Target) {
        switch target {
        case .showMoreItems, .showMoreCaptures:
            model.showMore(target)
        case .openItem(let id):
            let status = model.results.items.first { $0.id == id }?.status ?? .active
            close()
            environment.showItem(id: id, status: status)
        case .openCapture(let id):
            let query = model.query
            let hit = model.results.captures.first { $0.id == id }
            close()
            if let hit { environment.showCapture(hit, query: query) }
        }
    }

    private func makePanel() -> SearchPanel {
        let view = SearchPanelView(model: model, onOpen: { [weak self] in self?.open($0) }, onClose: { [weak self] in self?.close() })
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: view)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Search")
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        return panel
    }

    /// Centred horizontally on the display that holds the pointer, in its upper third.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.18))
    }
}
