import Foundation
import Testing
@testable import MemorriCore

@Suite struct CaptureRequestServiceTests {
    struct Rig {
        let service: CaptureRequestService
        let time: FakeTimeSource
        let feedback: FakeFeedback
        let onboarding: OnboardingCounter
        let settings: CaptureFeedbackSettings
        let permission: PermissionMonitor
        let runner: FakeCaptureRunner
    }

    private func makeRig(granted: Bool = true, outcome: CaptureOutcome? = .complete(displays: 1)) -> Rig {
        let checker = FakeScreenRecordingChecker(granted: granted)
        let time = FakeTimeSource(0)
        let feedback = FakeFeedback()
        let onboarding = OnboardingCounter()
        let settings = CaptureFeedbackSettings(store: FakeSettingsStore())
        let permission = PermissionMonitor(checker: checker)
        let runner = FakeCaptureRunner(outcome: outcome)
        let service = CaptureRequestService(
            runner: runner,
            permission: permission,
            feedback: feedback,
            settings: settings,
            time: time,
            onNeedsOnboarding: { onboarding.increment() }
        )
        return Rig(service: service, time: time, feedback: feedback, onboarding: onboarding,
                   settings: settings, permission: permission, runner: runner)
    }

    // MARK: Debounce and history (unchanged rules from spec 001)

    @Test func requestWithinDebounceWindowIsDropped() async {
        let rig = makeRig()
        #expect(await rig.service.request(.shortcut) != nil)
        rig.time.set(0.299)
        #expect(await rig.service.request(.shortcut) == nil)
        #expect(await rig.service.recent.count == 1)
        #expect(rig.runner.calls.count == 1)
    }

    @Test func requestAtDebounceLimitIsAccepted() async {
        let rig = makeRig()
        _ = await rig.service.request(.shortcut)
        rig.time.set(0.1)
        _ = await rig.service.request(.shortcut)      // dropped, must not push the window forward
        rig.time.set(0.3)
        #expect(await rig.service.request(.shortcut) != nil)
        #expect(await rig.service.recent.count == 2)
    }

    @Test func keepsOnlyTheNewest100() async {
        let rig = makeRig()
        for i in 0..<105 {
            rig.time.set(TimeInterval(i))
            _ = await rig.service.request(.menu)
        }
        let recent = await rig.service.recent
        #expect(recent.count == 100)
        #expect(recent.first?.timestamp == Date(timeIntervalSinceReferenceDate: 5))
        #expect(recent.last?.timestamp == Date(timeIntervalSinceReferenceDate: 104))
    }

    @Test func storesTriggerAndPermission() async {
        let rig = makeRig()
        _ = await rig.service.request(.shortcut)
        let request = await rig.service.recent.first
        #expect(request?.trigger == .shortcut)
        #expect(request?.permissionAtRequest == .granted)
        #expect(request?.timestamp == Date(timeIntervalSinceReferenceDate: 0))
    }

    // MARK: The pipeline decides, feedback follows the outcome

    @Test func theRequestGoesToTheCapturePipelineWithItsTrigger() async {
        let rig = makeRig()
        let outcome = await rig.service.request(.shortcut)
        #expect(outcome == .complete(displays: 1))
        #expect(rig.runner.calls == [.shortcut])
    }

    @Test func aCompleteCaptureFlashesAndPlaysOnce() async {
        let rig = makeRig(outcome: .complete(displays: 2))
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 1 && rig.feedback.soundCount == 1)
        #expect(rig.feedback.warningFlashCount == 0 && rig.feedback.warningSoundCount == 0)
        #expect(rig.onboarding.count == 0)
    }

    @Test func flashOffSkipsTheSuccessFlash() async {
        let rig = makeRig()
        rig.settings.flashIcon = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.soundCount == 1)
    }

    @Test func soundOffSkipsTheSuccessSound() async {
        let rig = makeRig()
        rig.settings.playSound = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 1 && rig.feedback.soundCount == 0)
    }

    @Test(arguments: [CaptureOutcome.partial(captured: 1, of: 2), .failed(reason: "Not enough free disk space")])
    func partialAndFailedPlayTheWarningPairInsteadOfSuccess(outcome: CaptureOutcome) async {
        let rig = makeRig(outcome: outcome)
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.warningFlashCount == 1 && rig.feedback.warningSoundCount == 1)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.soundCount == 0)
        #expect(rig.onboarding.count == 0)
    }

    @Test func warningsFollowTheSameTwoSwitches() async {
        let rig = makeRig(outcome: .failed(reason: "x"))
        rig.settings.flashIcon = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.warningFlashCount == 0 && rig.feedback.warningSoundCount == 1)
        rig.time.set(10)
        rig.settings.flashIcon = true
        rig.settings.playSound = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.warningFlashCount == 1 && rig.feedback.warningSoundCount == 1)
    }

    @Test func aRefusedPermissionPlaysNothingAndOpensOnboarding() async {
        let rig = makeRig(outcome: .permissionDenied)
        _ = await rig.service.request(.shortcut)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.soundCount == 0)
        #expect(rig.feedback.warningFlashCount == 0 && rig.feedback.warningSoundCount == 0)
        #expect(rig.onboarding.count == 1)
    }

    @Test func aRunIgnoredBecauseOneIsInProgressPlaysNothing() async {
        let rig = makeRig(outcome: nil)
        let outcome = await rig.service.request(.menu)
        #expect(outcome == nil)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.warningFlashCount == 0 && rig.onboarding.count == 0)
    }

    @Test func theTrackedPermissionNoLongerBlocksACapture() async {
        let rig = makeRig(granted: false)      // the real capture is the source of truth
        _ = await rig.service.request(.shortcut)
        #expect(rig.runner.calls.count == 1)
        #expect(await rig.service.recent.first?.permissionAtRequest == .notGranted)
    }

    @Test func feedbackHasASeparateWarningPair() async {
        let feedback = FakeFeedback()
        let player: any FeedbackPlaying = feedback
        await player.flashWarning()
        await player.playWarningSound()
        #expect(feedback.warningFlashCount == 1 && feedback.warningSoundCount == 1)
        #expect(feedback.flashCount == 0 && feedback.soundCount == 0)
    }

    @Test func aRefusedCaptureMarksThePermissionNotGrantedFromAnyTrackedState() async {
        let granted = makeRig(granted: true, outcome: .permissionDenied)
        _ = await granted.service.request(.shortcut)
        #expect(await granted.permission.status == .notGranted)
        #expect(granted.onboarding.count == 1)

        let restart = makeRig(granted: false, outcome: .permissionDenied)
        _ = await restart.permission.observeFreshProcess(granted: true)
        _ = await restart.service.request(.shortcut)
        #expect(await restart.permission.status == .notGranted)
        #expect(restart.onboarding.count == 1)
    }

    @Test(arguments: [CaptureOutcome.complete(displays: 2), .partial(captured: 1, of: 2)])
    func aCaptureThatWorkedMarksThePermissionGrantedEvenWhenItWasNot(outcome: CaptureOutcome) async {
        let notGranted = makeRig(granted: false, outcome: outcome)
        _ = await notGranted.service.request(.shortcut)
        #expect(await notGranted.permission.status == .granted)

        let restart = makeRig(granted: false, outcome: outcome)
        _ = await restart.permission.observeFreshProcess(granted: true)
        _ = await restart.service.request(.shortcut)
        #expect(await restart.permission.status == .granted)
        #expect(notGranted.onboarding.count == 0)
    }

    @Test func anotherFailureLeavesThePermissionStatusUnchanged() async {
        for start in [true, false] {
            let rig = makeRig(granted: start, outcome: .failed(reason: "Not enough free disk space"))
            _ = await rig.service.request(.shortcut)
            #expect(await rig.permission.status == (start ? .granted : .notGranted))
            #expect(rig.onboarding.count == 0)
        }
    }

    @Test func everyOutcomeIsReportedToTheOnOutcomeHook() async {
        let seen = OutcomeLog()
        let service = CaptureRequestService(
            runner: FakeCaptureRunner(outcome: .partial(captured: 1, of: 2)),
            permission: PermissionMonitor(checker: FakeScreenRecordingChecker(granted: true)),
            feedback: FakeFeedback(), settings: CaptureFeedbackSettings(store: FakeSettingsStore()),
            time: FakeTimeSource(0), onOutcome: { seen.add($0) }, onNeedsOnboarding: {})
        _ = await service.request(.menu)
        #expect(seen.values == [.partial(captured: 1, of: 2)])
    }
}

final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CaptureOutcome] = []
    var values: [CaptureOutcome] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ outcome: CaptureOutcome) { lock.lock(); items.append(outcome); lock.unlock() }

    // MARK: Window captures (spec 013)

    struct WindowRig {
        let service: CaptureRequestService
        let time: FakeTimeSource
        let feedback: FakeFeedback
        let onboarding: OnboardingCounter
        let settings: CaptureFeedbackSettings
        let permission: PermissionMonitor
        let runner: FakeCaptureRunner
        let windowRunner: FakeWindowRunner
        let outcomes: LockedBox<[CaptureOutcome]>
    }

    private func makeWindowRig(window: CaptureOutcome? = .windowComplete(app: "Mail"), full: CaptureOutcome? = .complete(displays: 1),
                               withWindowRunner: Bool = true) -> WindowRig {
        let time = FakeTimeSource(0)
        let feedback = FakeFeedback()
        let onboarding = OnboardingCounter()
        let settings = CaptureFeedbackSettings(store: FakeSettingsStore())
        let permission = PermissionMonitor(checker: FakeScreenRecordingChecker(granted: true))
        let runner = FakeCaptureRunner(outcome: full), windowRunner = FakeWindowRunner(outcome: window)
        let outcomes = LockedBox<[CaptureOutcome]>([])
        let service = CaptureRequestService(runner: runner, permission: permission, feedback: feedback, settings: settings, time: time,
                                            onOutcome: { outcome in outcomes.set(outcomes.value + [outcome]) },
                                            onNeedsOnboarding: { onboarding.increment() },
                                            windowRunner: withWindowRunner ? windowRunner : nil)
        return WindowRig(service: service, time: time, feedback: feedback, onboarding: onboarding, settings: settings, permission: permission,
                         runner: runner, windowRunner: windowRunner, outcomes: outcomes)
    }

    @Test func aWindowRequestGoesToTheWindowRunnerWithItsTriggerAndNeverToTheFullScreenRunner() async {
        let rig = makeWindowRig()
        let outcome = await rig.service.requestWindow(.shortcut)
        #expect(outcome == .windowComplete(app: "Mail"))
        #expect(rig.windowRunner.calls == [.shortcut] && rig.runner.calls.isEmpty)
        #expect(rig.outcomes.value == [.windowComplete(app: "Mail")])
    }

    @Test func aFullScreenRequestNeverGoesToTheWindowRunner() async {
        let rig = makeWindowRig()
        _ = await rig.service.request(.menu)
        #expect(rig.runner.calls == [.menu] && rig.windowRunner.calls.isEmpty)
    }

    @Test func aWindowRequestAndAFullScreenRequestWithinTheDebounceCountAsOne() async {
        let rig = makeWindowRig()
        #expect(await rig.service.requestWindow(.shortcut) != nil)
        rig.time.set(0.299)
        #expect(await rig.service.request(.shortcut) == nil)
        #expect(await rig.service.requestWindow(.menu) == nil)
        rig.time.set(0.3)
        #expect(await rig.service.request(.shortcut) != nil)
        #expect(rig.windowRunner.calls.count == 1 && rig.runner.calls.count == 1)
        #expect(await rig.service.recent.count == 2)
    }

    @Test func aWindowRequestIsKeptInTheHistoryWithItsTriggerAndPermission() async {
        let rig = makeWindowRig()
        _ = await rig.service.requestWindow(.menu)
        let request = await rig.service.recent.first
        #expect(request?.trigger == .menu && request?.permissionAtRequest == .granted)
    }

    @Test func aWindowCaptureFlashesAndPlaysTheUsualConfirmation() async {
        let rig = makeWindowRig()
        _ = await rig.service.requestWindow(.shortcut)
        #expect(rig.feedback.flashCount == 1 && rig.feedback.soundCount == 1)
        #expect(rig.feedback.warningFlashCount == 0 && rig.feedback.warningSoundCount == 0)
        rig.time.set(10)
        rig.settings.flashIcon = false
        _ = await rig.service.requestWindow(.shortcut)
        #expect(rig.feedback.flashCount == 1 && rig.feedback.soundCount == 2)
    }

    @Test(arguments: [CaptureOutcome.noWindow(.none), .noWindow(.ownWindow), .failed(reason: "the window is gone")])
    func noWindowAndFailuresPlayTheWarningPair(outcome: CaptureOutcome) async {
        let rig = makeWindowRig(window: outcome)
        _ = await rig.service.requestWindow(.shortcut)
        #expect(rig.feedback.warningFlashCount == 1 && rig.feedback.warningSoundCount == 1)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.soundCount == 0 && rig.onboarding.count == 0)
    }

    @Test func aRefusedPermissionOnAWindowRequestOpensOnboardingAndPlaysNothing() async {
        let rig = makeWindowRig(window: .permissionDenied)
        _ = await rig.service.requestWindow(.shortcut)
        #expect(rig.onboarding.count == 1)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.soundCount == 0)
        #expect(rig.feedback.warningFlashCount == 0 && rig.feedback.warningSoundCount == 0)
    }

    @Test func aWindowRequestWhileACaptureRunsPlaysNothing() async {
        let rig = makeWindowRig(window: nil)
        #expect(await rig.service.requestWindow(.shortcut) == nil)
        #expect(rig.feedback.flashCount == 0 && rig.feedback.warningFlashCount == 0 && rig.outcomes.value.isEmpty)
    }

    @Test func withoutAWindowRunnerAWindowRequestDoesNothing() async {
        let rig = makeWindowRig(withWindowRunner: false)
        #expect(await rig.service.requestWindow(.shortcut) == nil)
        #expect(rig.windowRunner.calls.isEmpty && rig.runner.calls.isEmpty && rig.feedback.flashCount == 0)
        #expect(await rig.service.recent.isEmpty)
    }
}
