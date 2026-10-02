import Foundation

/// Choosing the calendar and the list (spec 009 FR-002, FR-021): the user makes a calendar of its own, named `Memorri`, and the pickers
/// find it. Nothing else is ever chosen for the user.
public enum SyncTargets {
    /// The name the user gives Memorri's own calendar and list.
    public static let name = "Memorri"

    /// The container named `Memorri` (any case), or nil: no other is ever preselected.
    public static func preselect(_ containers: [SyncContainer]) -> String? {
        containers.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// What the picker shows for a container: `Memorri · iCloud`.
    public static func label(_ container: SyncContainer) -> String { container.account.isEmpty ? container.name : "\(container.name) · \(container.account)" }

    /// A notice for a container that already holds other entries; nil for an empty one.
    public static func notice(for container: SyncContainer) -> String? {
        container.holdsOtherEntries
            ? "\(container.name) already holds other entries. Memorri works best in a \(container.kind == .event ? "calendar" : "list") of its own, and it never changes entries it did not make."
            : nil
    }

    /// Whether the saved choice still exists among the containers the user can write to.
    public static func isStillAvailable(_ id: String?, in containers: [SyncContainer]) -> Bool { id.map { id in containers.contains { $0.id == id } } ?? false }
}
