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

/// Registers the global shortcuts (capture and search) and enforces the shortcut rules (FR-006, FR-007; spec 007 FR-009).
///
/// The recorder view saves a shortcut itself and then calls `recorderChanged`; a rejected
/// shortcut is reverted to the previous one right away. Each shortcut is also checked against the other one.
@MainActor @Observable
final class ShortcutAdapter {
    enum Action {
        case capture, search

        var name: KeyboardShortcuts.Name { self == .capture ? .capture : .search }
        /// How the other action names it in a refusal message.
        var label: String { self == .capture ? "Capture now" : "Search" }
    }

    private(set) var rejectionMessage: String?
    private(set) var searchRejectionMessage: String?
    private var accepted: KeyboardShortcuts.Shortcut?
    private var searchAccepted: KeyboardShortcuts.Shortcut?
    private let system = SystemShortcutAdapter()

    /// What the search shortcut does; set once the panel exists.
    var onSearch: @MainActor () -> Void = {}

    init(onCapture: @escaping @MainActor () -> Void) {
        accepted = KeyboardShortcuts.getShortcut(for: .capture)
        searchAccepted = KeyboardShortcuts.getShortcut(for: .search)
        Logger(subsystem: MemorriCore.subsystem, category: "shortcut")
            .notice("shortcut at launch: \(self.accepted?.description ?? "none", privacy: .public)")
        KeyboardShortcuts.onKeyUp(for: .capture) {
            Task { @MainActor in onCapture() }
        }
        KeyboardShortcuts.onKeyUp(for: .search) { [weak self] in
            Task { @MainActor in self?.onSearch() }
        }
    }

    /// The shortcut as text for menus, for example "⌃⌥⌘M". `nil` when none is set.
    var displayText: String? { accepted?.description }
    var searchDisplayText: String? { searchAccepted?.description }

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

    private func current(_ action: Action) -> KeyboardShortcuts.Shortcut? { action == .capture ? accepted : searchAccepted }

    private func set(_ shortcut: KeyboardShortcuts.Shortcut?, message: String?, for action: Action) {
        if action == .capture { accepted = shortcut; rejectionMessage = message } else { searchAccepted = shortcut; searchRejectionMessage = message }
    }

    private func apply(_ shortcut: KeyboardShortcuts.Shortcut?, for action: Action) {
        guard let shortcut else {            // cleared: no shortcut is registered
            set(nil, message: nil, for: action)
            return
        }
        let other: Action = action == .capture ? .search : .capture
        let others = current(other).map { [other.label: KeyCombo($0)] } ?? [:]
        if let rejection = ShortcutValidator(system: system, otherActions: others).validate(KeyCombo(shortcut)) {
            KeyboardShortcuts.setShortcut(current(action), for: action.name)   // keep the previous one
            set(current(action), message: Self.message(for: rejection), for: action)
        } else {
            set(shortcut, message: nil, for: action)
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
