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

    @Test func restartRequiredThenRevokedIsNotGranted() async {
        let checker = FakeScreenRecordingChecker(granted: false)
        let monitor = PermissionMonitor(checker: checker)
        checker.set(granted: true)
        _ = await monitor.refresh()
        checker.set(granted: false)
        #expect(await monitor.refresh() == .notGranted)
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
        checker.set(granted: false)
        _ = await monitor.refresh()      // restartRequired -> notGranted

        #expect(await iterator.next() == .notGranted)
        #expect(await iterator.next() == .restartRequired)
        #expect(await iterator.next() == .notGranted)
    }
}
