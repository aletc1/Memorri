import Testing
@testable import MemorriCore

@Suite struct SingleInstanceArbiterTests {
    @Test func aloneKeepsRunning() {
        #expect(SingleInstanceArbiter.shouldExit(ownPID: 500, otherPIDs: []) == false)
    }

    @Test func exitsWhenAnotherCopyHasALowerPID() {
        #expect(SingleInstanceArbiter.shouldExit(ownPID: 500, otherPIDs: [400]) == true)
    }

    @Test func keepsRunningWhenOnlyHigherPIDsExist() {
        #expect(SingleInstanceArbiter.shouldExit(ownPID: 500, otherPIDs: [600, 700]) == false)
    }

    @Test func ignoresItsOwnPID() {
        #expect(SingleInstanceArbiter.shouldExit(ownPID: 500, otherPIDs: [500]) == false)
    }

    @Test func exitsWhenAnyOtherCopyIsOlder() {
        #expect(SingleInstanceArbiter.shouldExit(ownPID: 500, otherPIDs: [900, 300, 700]) == true)
    }
}
