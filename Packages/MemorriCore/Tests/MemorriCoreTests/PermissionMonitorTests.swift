import Testing
@testable import MemorriCore

/// After launch, the permission is tracked only through `observeFreshProcess`, because a running
/// process keeps the answer it had at launch and can see neither a grant nor a revocation
/// (spike R5, and manual validation on 2026-09-29).
@Suite struct PermissionMonitorTests {
    private func monitor(launchGranted: Bool) -> PermissionMonitor {
        PermissionMonitor(checker: FakeScreenRecordingChecker(granted: launchGranted))
    }

    // MARK: launch

    @Test func launchGrantedIsGranted() async {
        #expect(await monitor(launchGranted: true).status == .granted)
    }

    @Test func launchNotGrantedIsNotGranted() async {
        #expect(await monitor(launchGranted: false).status == .notGranted)
    }

    @Test func freshMonitorAfterAGrantIsGranted() async {
        // A relaunch creates a new monitor that reads the current state.
        let checker = FakeScreenRecordingChecker(granted: false)
        let first = PermissionMonitor(checker: checker)
        _ = await first.observeFreshProcess(granted: true)
        checker.set(granted: true)
        #expect(await PermissionMonitor(checker: checker).status == .granted)
    }

    // MARK: after launch

    @Test func grantAfterLaunchNeedsARestart() async {
        let monitor = monitor(launchGranted: false)
        #expect(await monitor.observeFreshProcess(granted: true) == .restartRequired)
        #expect(await monitor.status == .restartRequired)
    }

    @Test func restartRequiredStaysWhileStillGranted() async {
        let monitor = monitor(launchGranted: false)
        _ = await monitor.observeFreshProcess(granted: true)
        #expect(await monitor.observeFreshProcess(granted: true) == .restartRequired)
    }

    @Test func noGrantKeepsNotGranted() async {
        #expect(await monitor(launchGranted: false).observeFreshProcess(granted: false) == .notGranted)
    }

    @Test func revocationWhileRunningIsNotGranted() async {
        let monitor = monitor(launchGranted: true)
        #expect(await monitor.observeFreshProcess(granted: false) == .notGranted)
    }

    @Test func stillGrantedStaysGranted() async {
        #expect(await monitor(launchGranted: true).observeFreshProcess(granted: true) == .granted)
    }

    @Test func revocationDuringRestartRequiredGoesBack() async {
        let monitor = monitor(launchGranted: false)
        _ = await monitor.observeFreshProcess(granted: true)
        #expect(await monitor.observeFreshProcess(granted: false) == .notGranted)
    }

    @Test func regrantAfterARevocationNeedsARestart() async {
        // Granted at launch, revoked, then granted again: the process cannot tell, so it asks
        // for a restart to be safe.
        let monitor = monitor(launchGranted: true)
        _ = await monitor.observeFreshProcess(granted: false)
        #expect(await monitor.observeFreshProcess(granted: true) == .restartRequired)
    }

    // MARK: updates

    @Test func updatesEmitCurrentThenEachChangeOnce() async {
        let monitor = monitor(launchGranted: false)
        var iterator = await monitor.statusUpdates().makeAsyncIterator()

        _ = await monitor.observeFreshProcess(granted: false)   // unchanged, must not emit
        _ = await monitor.observeFreshProcess(granted: true)    // -> restartRequired
        _ = await monitor.observeFreshProcess(granted: true)    // unchanged, must not emit
        _ = await monitor.observeFreshProcess(granted: false)   // -> notGranted

        #expect(await iterator.next() == .notGranted)
        #expect(await iterator.next() == .restartRequired)
        #expect(await iterator.next() == .notGranted)
    }

    // MARK: the real capture is the source of truth (spec 002, FR-007 and FR-010)

    @Test func aSuccessfulCaptureSetsGrantedFromAnyState() async {
        for launchGranted in [true, false] {
            let fromLaunch = monitor(launchGranted: launchGranted)
            await fromLaunch.captureSucceeded()
            #expect(await fromLaunch.status == .granted)
        }
        let restart = monitor(launchGranted: false)
        _ = await restart.observeFreshProcess(granted: true)
        #expect(await restart.status == .restartRequired)
        await restart.captureSucceeded()
        #expect(await restart.status == .granted)
    }

    @Test func aRefusedCaptureSetsNotGrantedFromAnyState() async {
        let granted = monitor(launchGranted: true)
        await granted.captureDeniedByPermission()
        #expect(await granted.status == .notGranted)

        let restart = monitor(launchGranted: false)
        _ = await restart.observeFreshProcess(granted: true)
        await restart.captureDeniedByPermission()
        #expect(await restart.status == .notGranted)

        let already = monitor(launchGranted: false)
        await already.captureDeniedByPermission()
        #expect(await already.status == .notGranted)
    }

    @Test func captureResultsEmitAChangeOnlyWhenTheStatusChanges() async {
        let monitor = monitor(launchGranted: true)
        var iterator = await monitor.statusUpdates().makeAsyncIterator()
        #expect(await iterator.next() == .granted)        // the current status first
        await monitor.captureSucceeded()                  // no change, nothing emitted
        await monitor.captureDeniedByPermission()
        #expect(await iterator.next() == .notGranted)
    }
}
