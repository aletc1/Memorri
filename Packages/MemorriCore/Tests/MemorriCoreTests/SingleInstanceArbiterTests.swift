import Foundation
import Testing
@testable import MemorriCore

/// The oldest copy keeps running. Process IDs wrap around on a busy Mac (they did during this
/// project's own testing), so a lower PID does not mean an older process.
@Suite struct SingleInstanceArbiterTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func instance(_ pid: Int32, _ launched: Date?) -> SingleInstanceArbiter.Instance {
        .init(pid: pid, launchDate: launched)
    }

    @Test func aloneKeepsRunning() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(10)), others: []) == false)
    }

    @Test func exitsWhenAnotherCopyIsOlder() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(10)), others: [instance(900, at(0))]) == true)
    }

    @Test func keepsRunningWhenTheOtherCopyIsNewer() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(0)), others: [instance(900, at(10))]) == false)
    }

    @Test func aWrappedLowerPIDDoesNotWinAgainstAnOlderCopy() {
        // The running copy has PID 99457. The new launch got PID 405 after the PIDs wrapped.
        let running = instance(99_457, at(0))
        let newcomer = instance(405, at(600))
        #expect(SingleInstanceArbiter.shouldExit(own: newcomer, others: [running]) == true)
        #expect(SingleInstanceArbiter.shouldExit(own: running, others: [newcomer]) == false)
    }

    @Test func ignoresItsOwnEntry() {
        let own = instance(500, at(10))
        #expect(SingleInstanceArbiter.shouldExit(own: own, others: [own]) == false)
    }

    @Test func exitsWhenAnyOtherCopyIsOlder() {
        let others = [instance(900, at(20)), instance(300, at(2)), instance(700, at(30))]
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(10)), others: others) == true)
    }

    @Test func sameLaunchTimeFallsBackToTheLowerPID() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(5)), others: [instance(400, at(5))]) == true)
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(5)), others: [instance(600, at(5))]) == false)
    }

    @Test func aCopyWithAnUnknownLaunchTimeCountsAsNewest() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, nil), others: [instance(900, at(0))]) == true)
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, at(0)), others: [instance(900, nil)]) == false)
    }

    @Test func bothUnknownFallsBackToTheLowerPID() {
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, nil), others: [instance(400, nil)]) == true)
        #expect(SingleInstanceArbiter.shouldExit(own: instance(500, nil), others: [instance(600, nil)]) == false)
    }
}
