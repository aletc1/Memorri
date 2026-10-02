import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import MemorriCore
import Observation
import os

extension KeyboardShortcuts.Name {
    /// The capture shortcut. Default is Control+Option+Command+M (ADR 0008).
    static let capture = Self("capture", default: .init(.m, modifiers: [.control, .option, .command]))
    /// The quick-search shortcut. Default is Control+Option+Command+F (spec 007).
    static let search = Self("search", default: .init(.f, modifiers: [.control, .option, .command]))
    /// The window-capture shortcut. Default is Control+Option+Command+W (spec 013).
    static let captureWindow = Self("captureWindow", default: .init(.w, modifiers: [.control, .option, .command]))
}

private extension KeyCombo {
    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        var modifiers: Set<Modifier> = []
        let flags = shortcut.modifiers
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self.init(keyCode: shortcut.carbonKeyCode, modifiers: modifiers)
    }
}

/// Asks macOS which shortcuts it owns. The package's own check is internal, so this calls
/// `CopySymbolicHotKeys()` directly (spike R3).
struct SystemShortcutAdapter: SystemShortcutChecking {
    func isReservedBySystem(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }

        var mask = 0
        if combo.modifiers.contains(.command) { mask |= cmdKey }
        if combo.modifiers.contains(.shift) { mask |= shiftKey }
        if combo.modifiers.contains(.option) { mask |= optionKey }
        if combo.modifiers.contains(.control) { mask |= controlKey }

        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int) == combo.keyCode
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int) == mask
        }
    }
}

/// Registers the global shortcuts (capture, window capture and search) and enforces the shortcut rules (FR-006, FR-007; spec 007 FR-009; spec 013 FR-003).
///
/// The recorder view saves a shortcut itself and then calls `recorderChanged`; a rejected
/// shortcut is reverted to the previous one right away. Each shortcut is also checked against all the others.
@MainActor @Observable
final class ShortcutAdapter {
    enum Action: CaseIterable {
        case capture, window, search

        var name: KeyboardShortcuts.Name {
            switch self {
            case .capture: .capture
            case .window: .captureWindow
            case .search: .search
            }
        }
        /// How the other actions name it in a refusal message.
        var label: String {
            switch self {
            case .capture: "Capture now"
            case .window: "Capture window"
            case .search: "Search"
            }
        }
    }

    private var messages: [Action: String] = [:]
    private var accepted: [Action: KeyboardShortcuts.Shortcut] = [:]
    private let system = SystemShortcutAdapter()

    /// What the search shortcut does; set once the panel exists.
    var onSearch: @MainActor () -> Void = {}

    init(onCapture: @escaping @MainActor () -> Void, onCaptureWindow: @escaping @MainActor () -> Void = {}) {
        for action in Action.allCases { accepted[action] = KeyboardShortcuts.getShortcut(for: action.name) }
        resolveWindowDefault()
        let logger = Logger(subsystem: MemorriCore.subsystem, category: "shortcut")
        logger.notice("shortcut at launch: \(self.accepted[.capture]?.description ?? "none", privacy: .public)")
        logger.notice("window shortcut at launch: \(self.accepted[.window]?.description ?? "none", privacy: .public)")
        KeyboardShortcuts.onKeyUp(for: .capture) {
            Task { @MainActor in onCapture() }
        }
        KeyboardShortcuts.onKeyUp(for: .captureWindow) {
            Task { @MainActor in onCaptureWindow() }
        }
        KeyboardShortcuts.onKeyUp(for: .search) { [weak self] in
            Task { @MainActor in self?.onSearch() }
        }
    }

    /// The default window-capture shortcut never takes a combination the user already gave to another action (spec 013, research R10).
    private func resolveWindowDefault() {
        let name = Action.window.name
        guard let defaultShortcut = name.defaultShortcut else { return }
        let others = Dictionary(uniqueKeysWithValues: Action.allCases.filter { $0 != .window }.compactMap { action in
            accepted[action].map { (action.label, KeyCombo($0)) }
        })
        switch DefaultShortcutResolver.resolve(default: KeyCombo(defaultShortcut), current: accepted[.window].map(KeyCombo.init), others: others) {
        case .keep: break
        case .unassign(let user):
            KeyboardShortcuts.setShortcut(nil, for: name)
            accepted[.window] = nil
            messages[.window] = DefaultShortcutResolver.message(usedBy: user)
        }
    }

    /// The shortcut of an action as text for menus, for example "⌃⌥⌘M". `nil` when none is set.
    func displayText(_ action: Action) -> String? { accepted[action]?.description }
    var displayText: String? { displayText(.capture) }
    var searchDisplayText: String? { displayText(.search) }
    var windowDisplayText: String? { displayText(.window) }

    /// Why the last shortcut recorded for the action was refused, or why it has none.
    func message(for action: Action) -> String? { messages[action] }

    /// Called by the recorder after the user recorded or cleared a shortcut.
    func recorderChanged(_ shortcut: KeyboardShortcuts.Shortcut?, for action: Action = .capture) {
        apply(shortcut, for: action)
    }

    /// Restores the default shortcut, subject to the same rules.
    func resetToDefault(_ action: Action = .capture) {
        let target = action.name.defaultShortcut
        KeyboardShortcuts.setShortcut(target, for: action.name)
        apply(target, for: action)
    }

    private func apply(_ shortcut: KeyboardShortcuts.Shortcut?, for action: Action) {
        guard let shortcut else {            // cleared: no shortcut is registered
            accepted[action] = nil
            messages[action] = nil
            return
        }
        let others = Dictionary(uniqueKeysWithValues: Action.allCases.filter { $0 != action }.compactMap { other in
            accepted[other].map { (other.label, KeyCombo($0)) }
        })
        if let rejection = ShortcutValidator(system: system, otherActions: others).validate(KeyCombo(shortcut)) {
            KeyboardShortcuts.setShortcut(accepted[action], for: action.name)   // keep the previous one
            messages[action] = Self.message(for: rejection)
        } else {
            accepted[action] = shortcut
            messages[action] = nil
        }
    }

    static func message(for rejection: ShortcutRejection) -> String {
        switch rejection {
        case .noModifier:
            "A shortcut needs at least one modifier key (Control, Option, Command or Shift)."
        case .usedByMemorriAction(let action):
            "This shortcut is already used by \(action) in Memorri."
        case .reservedBySystem:
            "macOS already uses this shortcut."
        }
    }
}
