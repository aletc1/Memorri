import Foundation
import Testing
@testable import MemorriCore

/// `Open Memorri at login` follows what the system says (spec 010 FR-014, FR-015, SC-009).
@Suite struct LoginItemTests {
    final class FakeController: LoginItemControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: LoginItemStatus
        private(set) var calls: [String] = []
        var failing = false
        /// What registering gives: the system may want the user's approval first.
        var afterRegister: LoginItemStatus = .enabled
        init(_ status: LoginItemStatus = .off) { _status = status }
        var status: LoginItemStatus { lock.withLock { _status } }
        func set(_ status: LoginItemStatus) { lock.withLock { _status = status } }
        func register() throws { calls.append("register"); if failing { throw CocoaError(.fileWriteNoPermission) }; set(afterRegister) }
        func unregister() throws { calls.append("unregister"); if failing { throw CocoaError(.fileWriteNoPermission) }; set(.off) }
    }

    @Test func itIsOffByDefaultAndShowsWhatTheSystemSays() {
        let controller = FakeController()
        let item = LoginItem(controller: controller)
        #expect(item.status == .off && !item.isOn)
        controller.set(.enabled)                                   // switched on elsewhere
        #expect(item.isOn)
        controller.set(.off)                                       // removed in System Settings: the switch follows at once
        #expect(!item.isOn)
    }

    @Test func switchingOnRegistersAndOffUnregistersOnlyWhenThereIsSomethingToRemove() throws {
        let controller = FakeController()
        let item = LoginItem(controller: controller)
        #expect(try item.setOn(true) == .enabled && controller.calls == ["register"])
        #expect(try item.setOn(true) == .enabled && controller.calls == ["register"])         // already on: nothing to do
        #expect(try item.setOn(false) == .off && controller.calls == ["register", "unregister"])
        #expect(try item.setOn(false) == .off && controller.calls == ["register", "unregister"])
    }

    @Test func aPendingApprovalIsReportedNotHiddenAndCountsAsWaiting() throws {
        let controller = FakeController(); controller.afterRegister = .requiresApproval
        let item = LoginItem(controller: controller)
        #expect(try item.setOn(true) == .requiresApproval)
        #expect(!item.isOn && item.waitsForApproval)
        #expect(item.note?.contains("approve") == true)
        #expect(LoginItem(controller: FakeController(.enabled)).note == nil)
        #expect(try item.setOn(false) == .off)                                                  // an approval that was never given can be withdrawn
    }

    @Test func aRefusalByTheSystemIsPassedOn() {
        let controller = FakeController(); controller.failing = true
        let item = LoginItem(controller: controller)
        #expect(throws: (any Error).self) { try item.setOn(true) }
        #expect(!item.isOn)
    }
}
