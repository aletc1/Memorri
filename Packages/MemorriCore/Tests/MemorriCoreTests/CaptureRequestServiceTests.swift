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
        let checker: FakeScreenRecordingChecker
    }

    private func makeRig(granted: Bool = true) -> Rig {
        let checker = FakeScreenRecordingChecker(granted: granted)
        let time = FakeTimeSource(0)
        let feedback = FakeFeedback()
        let onboarding = OnboardingCounter()
        let settings = CaptureFeedbackSettings(store: FakeSettingsStore())
        let service = CaptureRequestService(
            permission: PermissionMonitor(checker: checker),
            feedback: feedback,
            settings: settings,
            time: time,
            onNeedsOnboarding: { onboarding.increment() }
        )
        return Rig(service: service, time: time, feedback: feedback, onboarding: onboarding,
                   settings: settings, checker: checker)
    }

    @Test func requestWithinDebounceWindowIsDropped() async {
        let rig = makeRig()
        #expect(await rig.service.request(.shortcut) != nil)
        rig.time.set(0.299)
        #expect(await rig.service.request(.shortcut) == nil)
        #expect(await rig.service.recent.count == 1)
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

    @Test func grantedWithBothOnFlashesAndPlaysOnce() async {
        let rig = makeRig()
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 1)
        #expect(rig.feedback.soundCount == 1)
        #expect(rig.onboarding.count == 0)
    }

    @Test func flashOffSkipsTheFlash() async {
        let rig = makeRig()
        rig.settings.flashIcon = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 0)
        #expect(rig.feedback.soundCount == 1)
    }

    @Test func soundOffSkipsTheSound() async {
        let rig = makeRig()
        rig.settings.playSound = false
        _ = await rig.service.request(.menu)
        #expect(rig.feedback.flashCount == 1)
        #expect(rig.feedback.soundCount == 0)
    }

    @Test func notGrantedRecordsButOnlyOpensOnboarding() async {
        let rig = makeRig(granted: false)
        let request = await rig.service.request(.shortcut)
        #expect(request?.permissionAtRequest == .notGranted)
        #expect(await rig.service.recent.count == 1)
        #expect(rig.feedback.flashCount == 0)
        #expect(rig.feedback.soundCount == 0)
        #expect(rig.onboarding.count == 1)
    }

    @Test func restartRequiredIsTreatedAsNotGranted() async {
        let rig = makeRig(granted: false)
        rig.checker.set(granted: true)        // granted while the app runs
        let request = await rig.service.request(.menu)
        #expect(request?.permissionAtRequest == .restartRequired)
        #expect(rig.feedback.flashCount == 0)
        #expect(rig.onboarding.count == 1)
    }

    @Test func storesTriggerAndPermission() async {
        let rig = makeRig()
        let request = await rig.service.request(.shortcut)
        #expect(request?.trigger == .shortcut)
        #expect(request?.permissionAtRequest == .granted)
        #expect(request?.timestamp == Date(timeIntervalSinceReferenceDate: 0))
    }
}
