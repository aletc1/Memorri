import Foundation
import Testing
@testable import MemorriCore

@Suite struct ContextMatcherTests {
    private func context(_ id: String, _ hints: [ContextHint]) -> ContextRecord { ContextRecord(id: id, name: id, timezone: nil, hints: hints) }
    private func hint(_ kind: ContextHint.Kind, _ value: String) -> ContextHint { ContextHint(kind: kind, value: value) }
    private func window(app: String? = nil, bundle: String? = nil, title: String? = nil) -> WindowInfo {
        WindowInfo(appName: app, bundleID: bundle, title: title, frame: PixelBox(x: 0, y: 0, width: 100, height: 100))
    }
    private func tag(_ key: String, _ value: String) -> CaptureTag { CaptureTag(key: key, value: value, confidence: 1, source: "code") }
    private func line(_ text: String, n: Int = 1) -> RecognisedLine { RecognisedLine(n: n, text: text, box: PixelBox(x: 0, y: 0, width: 10, height: 10), confidence: 0.9) }

    private func decide(_ contexts: [ContextRecord], windows: [WindowInfo] = [], tags: [CaptureTag] = [], lines: [RecognisedLine] = []) -> ContextDecision {
        ContextMatcher.decide(contexts: contexts, windows: windows, tags: tags, lines: lines)
    }

    @Test func eachKindOfHintScoresItsPoints() {
        #expect(ContextMatcher.points(for: .windowTitle) == 3 && ContextMatcher.points(for: .app) == 3)
        #expect(ContextMatcher.points(for: .domain) == 2.5 && ContextMatcher.points(for: .keyword) == 1)
        #expect(ContextMatcher.minimumScore == 2 && ContextMatcher.minimumLead == 1)
    }

    @Test func aWindowTitleHintMatchesATitleIgnoringCase() {
        let a = context("A", [hint(.windowTitle, "customer a")])
        let decision = decide([a, context("B", [hint(.windowTitle, "Customer B")])], windows: [window(title: "Calendar - CUSTOMER A - Outlook")])
        #expect(decision.contextID == "A" && decision.source == .auto && decision.score == 3)
        #expect(decision.matched == [MatchedHint(hintKind: "window_title", value: "customer a", points: 3)])
    }

    @Test func anApplicationHintMatchesTheAppNameOrBundleId() {
        let a = context("A", [hint(.app, "Outlook")])
        #expect(decide([a], windows: [window(app: "Microsoft Outlook")]).contextID == "A")
        #expect(decide([a], windows: [window(bundle: "com.microsoft.Outlook")]).contextID == "A")
        #expect(decide([a], tags: [tag("application", "Outlook")]).contextID == "A")
        #expect(decide([a], windows: [window(app: "Safari")]).source == .none)
    }

    @Test func aDomainHintMatchesTagValuesAndLinesButNotWindowTitles() {
        let a = context("A", [hint(.domain, "customer-a.example")])
        #expect(decide([a], tags: [tag("domain", "customer-a.example")]).contextID == "A")
        #expect(decide([a], tags: [tag("account", "ana@customer-a.example")]).contextID == "A")
        #expect(decide([a], lines: [line("To: ana@customer-a.example")]).contextID == "A")
        #expect(decide([a], windows: [window(title: "customer-a.example - Mail")]).source == .none)
        #expect(decide([a], lines: [line("x")]).score == 0)
    }

    @Test func aKeywordIsWorthOnePointSoItNeedsHelp() {
        let a = context("A", [hint(.keyword, "Atlas")])
        #expect(decide([a], lines: [line("Project Atlas kickoff")]).source == .none)
        let withTitle = context("A", [hint(.keyword, "Atlas"), hint(.windowTitle, "Project")])
        let decision = decide([withTitle], windows: [window(title: "Project board")], lines: [line("Atlas")])
        #expect(decision.contextID == "A" && decision.score == 4)
    }

    @Test func aHintCountsOnceHoweverOftenItAppears() {
        let a = context("A", [hint(.keyword, "atlas")])
        let decision = decide([a, context("B", [hint(.windowTitle, "Board")])], windows: [window(title: "Board"), window(title: "Board")],
                              lines: [line("atlas"), line("atlas", n: 2), line("atlas", n: 3)])
        #expect(decision.contextID == "B" && decision.score == 3)
        #expect(decision.runnerUp == RunnerUp(contextId: "A", score: 1))
    }

    @Test func atLeastTwoPointsAreNeeded() {
        let a = context("A", [hint(.keyword, "atlas")])
        let decision = decide([a], lines: [line("atlas")])
        #expect(decision.source == .none && decision.contextID == nil && decision.score == 0)
        #expect(decision.runnerUp == RunnerUp(contextId: "A", score: 1))
    }

    @Test func aLeadOfAtLeastOnePointIsNeeded() {
        let a = context("A", [hint(.windowTitle, "Alpha")])
        let b = context("B", [hint(.domain, "beta.example"), hint(.keyword, "beta")])        // 3.5 points
        let close = decide([a, b], windows: [window(title: "Alpha")], tags: [tag("domain", "beta.example")], lines: [line("beta")])
        #expect(close.source == .none && close.contextID == nil)                           // 3 against 3.5: no lead of 1
        #expect(close.runnerUp?.contextId == "A" || close.runnerUp?.contextId == "B")
        let clear = decide([a, context("C", [hint(.keyword, "gamma")])], windows: [window(title: "Alpha")], lines: [line("gamma")])
        #expect(clear.contextID == "A")                                                     // 3 against 1
    }

    @Test func twoEqualScoresAreATieAndBothAreRecorded() {
        let a = context("A", [hint(.windowTitle, "Shared")]), b = context("B", [hint(.app, "Outlook")])
        let decision = decide([a, b], windows: [window(app: "Outlook", title: "Shared")])
        #expect(decision.source == .none && decision.contextID == nil)
        #expect(decision.runnerUp?.tie == true && Set(decision.runnerUp?.contextIds ?? []) == ["A", "B"])
    }

    @Test func noContextsOrNoMatchIsNone() {
        #expect(decide([]) == .unassigned)
        let decision = decide([context("A", [hint(.windowTitle, "Nothing")])], windows: [window(title: "Else")])
        #expect(decision.source == .none && decision.contextID == nil && decision.matched.isEmpty && decision.runnerUp == nil)
    }

    @Test func theDecisionNamesWhatMatched() {
        let a = context("A", [hint(.windowTitle, "Customer A"), hint(.app, "Outlook"), hint(.domain, "a.example"), hint(.keyword, "atlas")])
        let decision = decide([a], windows: [window(app: "Outlook", title: "Customer A")], tags: [tag("domain", "a.example")], lines: [line("Atlas")])
        #expect(decision.score == 9.5)
        #expect(Set(decision.matched.map(\.hintKind)) == ["window_title", "app", "domain", "keyword"])
    }

    @Test func aRemoteClientTagMatchesAnAppHint() {
        let a = context("A", [hint(.app, "Citrix")])
        #expect(decide([a], tags: [tag("remote_client", "Citrix Viewer")]).contextID == "A")
        #expect(decide([a], tags: [tag("remote_session", "Citrix")]).contextID == "A")
    }

    @Test func anAccountOrDomainTagMatchesADomainHint() {
        let a = context("A", [hint(.domain, "customer-a.example")])
        #expect(decide([a], tags: [tag("account", "ana@customer-a.example")]).contextID == "A")
        #expect(decide([a], tags: [tag("domain", "portal.customer-a.example")]).contextID == "A")
        #expect(decide([a], tags: [tag("domain", "other.example")]).source == .none)
    }

    @Test func titleKeywordTagsCountForKeywordHints() {
        let a = context("A", [hint(.keyword, "budget"), hint(.app, "Outlook")])
        #expect(decide([a], windows: [window(app: "Outlook")], tags: [tag("window_title_keywords", "budget")]).score == 4)
    }
}
