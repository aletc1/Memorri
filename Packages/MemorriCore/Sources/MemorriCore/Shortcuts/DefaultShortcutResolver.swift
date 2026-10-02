import Foundation

/// What to do with the default shortcut of a new action when the app starts (spec 013, research R10). A default must never take a combination
/// the user already gave to another Memorri action: then the new action starts without a shortcut and says why.
public enum DefaultShortcutResolver {
    public enum Decision: Equatable, Sendable {
        case keep
        /// The default is not used, because the action named here already has it.
        case unassign(usedBy: String)
    }

    /// - Parameters:
    ///   - default: the combination the action ships with.
    ///   - current: what is assigned to the action now (`nil` when the user cleared it).
    ///   - others: the shortcuts of the other Memorri actions, by action name.
    public static func resolve(default defaultCombo: KeyCombo, current: KeyCombo?, others: [String: KeyCombo]) -> Decision {
        guard current == defaultCombo, let name = others.first(where: { $0.value == defaultCombo })?.key else { return .keep }
        return .unassign(usedBy: name)
    }

    public static func message(usedBy action: String) -> String {
        "The default shortcut is already used by \(action) in Memorri, so none is set. Record another one, or use the menu."
    }
}
