import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import MemorriCore
import Observation
import os

extension KeyboardShortcuts.Name {
    /// The capture shortcut. Default is Control+Option+Command+M (ADR 0008).
    static let capture = Self("capture", default: .init(.m, modifiers: [.control, .option, .command]))
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

/// Registers the global capture shortcut and enforces the shortcut rules (FR-006, FR-007).
///
/// The recorder view saves a shortcut itself and then calls `recorderChanged`; a rejected
/// shortcut is reverted to the previous one right away.
@MainActor @Observable
final class ShortcutAdapter {
    private(set) var rejectionMessage: String?
    private var accepted: KeyboardShortcuts.Shortcut?
    private let validator = ShortcutValidator(system: SystemShortcutAdapter(), otherActions: [:])

    init(onCapture: @escaping @MainActor () -> Void) {
        accepted = KeyboardShortcuts.getShortcut(for: .capture)
        Logger(subsystem: MemorriCore.subsystem, category: "shortcut")
            .notice("shortcut at launch: \(self.accepted?.description ?? "none", privacy: .public)")
        KeyboardShortcuts.onKeyUp(for: .capture) {
            Task { @MainActor in onCapture() }
        }
    }

    /// The shortcut as text for menus, for example "⌃⌥⌘M". `nil` when none is set.
    var displayText: String? { accepted?.description }

    /// Called by the recorder after the user recorded or cleared a shortcut.
    func recorderChanged(_ shortcut: KeyboardShortcuts.Shortcut?) {
        apply(shortcut)
    }

    /// Restores the default shortcut, subject to the same rules.
    func resetToDefault() {
        let target = KeyboardShortcuts.Name.capture.defaultShortcut
        KeyboardShortcuts.setShortcut(target, for: .capture)
        apply(target)
    }

    private func apply(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut else {            // cleared: no shortcut is registered
            accepted = nil
            rejectionMessage = nil
            return
        }
        if let rejection = validator.validate(KeyCombo(shortcut)) {
            KeyboardShortcuts.setShortcut(accepted, for: .capture)   // keep the previous one
            rejectionMessage = Self.message(for: rejection)
        } else {
            accepted = shortcut
            rejectionMessage = nil
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
