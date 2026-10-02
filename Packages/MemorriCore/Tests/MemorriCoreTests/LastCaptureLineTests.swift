import Testing
@testable import MemorriCore

@Suite struct LastCaptureLineTests {
    @Test func noCaptureYet() {
        #expect(LastCaptureLine.text(for: nil, age: 0) == "No capture yet")
    }

    @Test func completeFailedAndPartialTexts() {
        #expect(LastCaptureLine.text(for: .complete, age: 5) == "Last capture: complete, just now")
        #expect(LastCaptureLine.text(for: .partial(captured: 2, of: 3), age: 120)
                == "Last capture: 2 of 3 displays captured, 2 min ago")
        #expect(LastCaptureLine.text(for: .failed(reason: "Not enough free disk space"), age: 3 * 3600)
                == "Last capture failed: Not enough free disk space, 3 h ago")
    }

    @Test func aWindowCaptureNamesTheApplication() {
        #expect(LastCaptureLine.text(for: .window(app: "Mail"), age: 5) == "Last window capture: Mail, just now")
        #expect(LastCaptureLine.text(for: .window(app: nil), age: 120) == "Last window capture, 2 min ago")
        #expect(LastCaptureLine.text(for: .window(app: "  "), age: 5) == "Last window capture, just now")
    }

    @Test func aWindowCaptureWithNothingToCaptureReadsAsAFailure() {
        #expect(LastCaptureLine.text(for: .failed(reason: ActiveWindowReason.none.message), age: 5) == "Last capture failed: no window to capture, just now")
        #expect(LastCaptureLine.text(for: .failed(reason: ActiveWindowReason.ownWindow.message), age: 5)
                == "Last capture failed: Memorri's own windows are not captured, just now")
    }

    @Test func ageBoundaries() {
        #expect(LastCaptureLine.age(59) == "just now")
        #expect(LastCaptureLine.age(60) == "1 min ago")
        #expect(LastCaptureLine.age(3599) == "59 min ago")
        #expect(LastCaptureLine.age(3600) == "1 h ago")
        #expect(LastCaptureLine.age(86399) == "23 h ago")
        #expect(LastCaptureLine.age(86400) == "1 d ago")
        #expect(LastCaptureLine.age(-5) == "just now")
    }
}
