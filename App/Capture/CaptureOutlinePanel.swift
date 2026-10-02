import AppKit
import MemorriCore

/// Shows the red outline of a window capture (spec 013 FR-010 to FR-012, research R8): one borderless panel per display the recorded area touches,
/// drawn inside the area, shown for about a second and faded out. It takes no focus, lets every click and key through, is left out of screen
/// sharing and is made only after the picture is stored, so it is never in the picture.
struct CaptureOutlinePanel: CaptureOutlining {
    func showOutline(for frame: DesktopRect) async {
        await MainActor.run { OutlineController.shared.show(frame) }
    }
}

@MainActor
private final class OutlineController {
    static let shared = OutlineController()

    /// How long the outline stays before it fades, and how long the fade takes.
    private static let visibleFor: Duration = .milliseconds(1000)
    private static let fade: TimeInterval = 0.25
    private static let lineWidth: CGFloat = 4

    private var panels: [NSPanel] = []
    private var generation = 0

    func show(_ frame: DesktopRect) {
        remove()
        generation += 1
        let screens = NSScreen.screens
        guard let main = screens.first else { return }
        // NSScreen frames have their origin at the bottom left of the main display; the desktop rectangle has it at the top left.
        let displays = screens.map { DesktopRect(x: $0.frame.minX, y: main.frame.maxY - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        for segment in CaptureOutlineGeometry.segments(for: frame, displays: displays) {
            let screen = screens[segment.displayIndex]
            let rect = NSRect(x: screen.frame.minX + segment.rect.x,
                              y: screen.frame.minY + screen.frame.height - segment.rect.y - segment.rect.height,
                              width: segment.rect.width, height: segment.rect.height)
            panels.append(makePanel(rect))
        }
        let shown = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            self?.fadeOut(generation: shown)
        }
    }

    private func makePanel(_ rect: NSRect) -> NSPanel {
        let panel = OutlineWindow(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.animationBehavior = .none
        panel.contentView = OutlineView(frame: NSRect(origin: .zero, size: rect.size), lineWidth: Self.lineWidth)
        panel.setFrame(rect, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        return panel
    }

    private func fadeOut(generation shown: Int) {
        guard shown == generation else { return }
        let fading = panels
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            fading.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            Task { @MainActor in if self?.generation == shown { self?.remove() } }
        }
    }

    private func remove() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

/// A panel that can never become the key or main window, so showing it takes nothing from the app the user is working in.
private final class OutlineWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A red line just inside the edge of its bounds.
private final class OutlineView: NSView {
    private let lineWidth: CGFloat

    init(frame: NSRect, lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        path.lineWidth = lineWidth
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
