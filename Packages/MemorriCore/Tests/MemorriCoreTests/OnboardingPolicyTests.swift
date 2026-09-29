import Testing
@testable import MemorriCore

@Suite struct OnboardingPolicyTests {
    @Test(arguments: [ScreenRecordingStatus.notGranted, .restartRequired])
    func firstLaunchWithoutPermissionOpensOnboarding(status: ScreenRecordingStatus) {
        #expect(OnboardingPolicy.shouldOpenAtLaunch(completed: false, status: status) == true)
    }

    @Test func firstLaunchWithPermissionDoesNotOpenOnboarding() {
        #expect(OnboardingPolicy.shouldOpenAtLaunch(completed: false, status: .granted) == false)
    }

    @Test(arguments: [ScreenRecordingStatus.granted, .notGranted, .restartRequired])
    func laterLaunchesNeverOpenOnboardingOnTheirOwn(status: ScreenRecordingStatus) {
        #expect(OnboardingPolicy.shouldOpenAtLaunch(completed: true, status: status) == false)
    }

    @Test func decidingAtLaunchMarksOnboardingCompleted() {
        let store = FakeSettingsStore()
        let policy = OnboardingPolicy(store: store)
        #expect(policy.decideAtLaunch(status: .notGranted) == true)
        #expect(store.rawValue(forKey: "memorri.onboarding.completed") == true)
        // The next launch does not open it again, even though the permission is still missing.
        #expect(policy.decideAtLaunch(status: .notGranted) == false)
    }

    @Test func firstLaunchWithPermissionStillMarksCompleted() {
        let store = FakeSettingsStore()
        let policy = OnboardingPolicy(store: store)
        #expect(policy.decideAtLaunch(status: .granted) == false)
        #expect(store.rawValue(forKey: "memorri.onboarding.completed") == true)
        // Permission revoked later: no automatic window on a later launch.
        #expect(policy.decideAtLaunch(status: .notGranted) == false)
    }
}
