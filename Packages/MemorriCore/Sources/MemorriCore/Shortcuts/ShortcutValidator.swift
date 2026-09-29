/// A key plus modifier keys, independent of any UI library.
public struct KeyCombo: Hashable, Sendable {
    public enum Modifier: Hashable, Sendable {
        case control, option, command, shift
    }

    public let keyCode: Int
    public let modifiers: Set<Modifier>

    public init(keyCode: Int, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Why a shortcut was refused. The messages shown to the user are in `contracts/ui-contract.md`.
public enum ShortcutRejection: Equatable, Sendable {
    case noModifier
    case usedByMemorriAction(String)
    case reservedBySystem
}

/// Asks macOS whether a combo is one of its own shortcuts.
public protocol SystemShortcutChecking: Sendable {
    func isReservedBySystem(_ combo: KeyCombo) -> Bool
}

/// Decides whether a newly recorded shortcut may be saved. Rules apply in this order and the
/// first failure wins: no modifier, used by another Memorri action, reserved by macOS.
/// Shortcuts owned by other apps cannot be detected and are not checked.
public struct ShortcutValidator: Sendable {
    private let system: any SystemShortcutChecking
    private let otherActions: [String: KeyCombo]

    /// - Parameter otherActions: the shortcuts of the other Memorri actions, by action name.
    public init(system: any SystemShortcutChecking, otherActions: [String: KeyCombo]) {
        self.system = system
        self.otherActions = otherActions
    }

    /// Returns `nil` when the combo is accepted.
    public func validate(_ combo: KeyCombo) -> ShortcutRejection? {
        if combo.modifiers.isEmpty { return .noModifier }
        if let name = otherActions.first(where: { $0.value == combo })?.key {
            return .usedByMemorriAction(name)
        }
        if system.isReservedBySystem(combo) { return .reservedBySystem }
        return nil
    }
}
