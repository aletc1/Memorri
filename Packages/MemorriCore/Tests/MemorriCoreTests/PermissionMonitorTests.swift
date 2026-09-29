import Testing
@testable import MemorriCore

@Suite struct PermissionMonitorTests {
    @Test func launchGrantedIsGranted() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: true))
        #expect(await monitor.status == .granted)
    }

    @Test func launchNotGrantedIsNotGranted() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: false))
        #expect(await monitor.status == .notGranted)
    }

    @Test func grantedWhileRunningNeedsRestart() async {
        let checker = FakeScreenRecordingChecker(granted: false)
        let monitor = PermissionMonitor(checker: checker)
        checker.set(granted: true)
        #expect(await monitor.refresh() == .restartRequired)
        #expect(await monitor.status == .restartRequired)
    }

    @Test func revokedWhileRunningIsNotGranted() async {
        let checker = FakeScreenRecordingChecker(granted: true)
        let monitor = PermissionMonitor(checker: checker)
        checker.set(granted: false)
        #expect(await monitor.refresh() == .notGranted)
    }

    @Test func restartRequiredStaysUntilRelaunch() async {
        let checker = FakeScreenRecordingChecker(granted: false)
        let monitor = PermissionMonitor(checker: checker)
        checker.set(granted: true)
        _ = await monitor.refresh()
        #expect(await monitor.refresh() == .restartRequired)
    }

    @Test func inProcessCheckCannotEndRestartRequired() async {
        // This process cannot see a grant made after launch, so its own reading is always
        // "not granted" in this state. It must not undo the state on every poll.
        let checker = FakeScreenRecordingChecker(granted: false)
        let monitor = PermissionMonitor(checker: checker)
        _ = await monitor.observeFreshProcess(granted: true)
        #expect(await monitor.refresh() == .restartRequired)
        #expect(await monitor.refresh() == .restartRequired)
    }

    @Test func freshMonitorAfterGrantIsGranted() async {
        let checker = FakeScreenRecordingChecker(granted: false)
        let first = PermissionMonitor(checker: checker)
        checker.set(granted: true)
        _ = await first.refresh()
        // A relaunch creates a new monitor that reads the current state.
        let relaunched = PermissionMonitor(checker: checker)
        #expect(await relaunched.status == .granted)
    }

    @Test func unchangedStatusStaysGranted() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: true))
        #expect(await monitor.refresh() == .granted)
        #expect(await monitor.refresh() == .granted)
    }

    @Test func updatesEmitCurrentThenEachChangeOnce() async {
        let checker = FakeScreenRecordingChecker(granted: false)
        let monitor = PermissionMonitor(checker: checker)
        var iterator = await monitor.statusUpdates().makeAsyncIterator()

        checker.set(granted: true)
        _ = await monitor.refresh()      // notGranted -> restartRequired
        _ = await monitor.refresh()      // unchanged, must not emit
        _ = await monitor.observeFreshProcess(granted: false)   // restartRequired -> notGranted

        #expect(await iterator.next() == .notGranted)
        #expect(await iterator.next() == .restartRequired)
        #expect(await iterator.next() == .notGranted)
    }

    // A running process keeps the answer it had at launch, so a grant made afterwards is only
    // visible to a freshly started copy of the app (spike R5, and the check on 2026-09-29).

    @Test func freshProcessSeeingAGrantNeedsARestart() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: false))
        #expect(await monitor.observeFreshProcess(granted: true) == .restartRequired)
        #expect(await monitor.status == .restartRequired)
    }

    @Test func freshProcessSeeingNoGrantKeepsNotGranted() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: false))
        #expect(await monitor.observeFreshProcess(granted: false) == .notGranted)
    }

    @Test func freshProcessSeeingARevocationAfterAGrantGoesBack() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: false))
        _ = await monitor.observeFreshProcess(granted: true)
        #expect(await monitor.observeFreshProcess(granted: false) == .notGranted)
    }

    @Test func freshProcessDoesNotChangeAGrantedStatus() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: true))
        #expect(await monitor.observeFreshProcess(granted: true) == .granted)
        // A stale "denied" from a probe must not undo a permission this process already holds.
        #expect(await monitor.observeFreshProcess(granted: false) == .granted)
    }

    @Test func freshProcessChangesAreEmittedOnce() async {
        let monitor = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: false))
        var iterator = await monitor.statusUpdates().makeAsyncIterator()
        _ = await monitor.observeFreshProcess(granted: true)
        _ = await monitor.observeFreshProcess(granted: true)     // unchanged, must not emit
        _ = await monitor.observeFreshProcess(granted: false)
        #expect(await iterator.next() == .notGranted)
        #expect(await iterator.next() == .restartRequired)
        #expect(await iterator.next() == .notGranted)
    }
}
