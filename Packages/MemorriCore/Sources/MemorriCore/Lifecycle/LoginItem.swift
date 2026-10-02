import Foundation

public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    /// Registered, but macOS waits for the user to approve it in System Settings.
    case requiresApproval
    case off
}

/// The system's login item service, behind a protocol so the setting is tested without touching the real one.
public protocol LoginItemControlling: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// `Open Memorri at login` (spec 010). Nothing is stored: the switch always shows what the system says, so removing the item in System Settings turns
/// the switch off.
public struct LoginItem: Sendable {
    private let controller: any LoginItemControlling

    public init(controller: any LoginItemControlling) { self.controller = controller }

    public var status: LoginItemStatus { controller.status }
    public var isOn: Bool { status == .enabled }
    public var waitsForApproval: Bool { status == .requiresApproval }

    /// A line for the settings when the system needs the user's approval.
    public var note: String? {
        waitsForApproval ? "macOS needs you to approve Memorri as a login item in System Settings > General > Login Items." : nil
    }

    /// Switches it on or off and returns the system's state afterwards.
    @discardableResult
    public func setOn(_ on: Bool) throws -> LoginItemStatus {
        if on {
            if status != .enabled { try controller.register() }
        } else if status != .off {
            try controller.unregister()
        }
        return status
    }
}
