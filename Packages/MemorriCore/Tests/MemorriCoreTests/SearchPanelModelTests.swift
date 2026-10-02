import Foundation
import Testing
@testable import MemorriCore

@Suite struct SearchPanelModelTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func item(_ id: String = "i", title: String = "Café - Pruebas", kind: FindingKind = .appointment, matchedIn: SearchField = .title,
                      status: ItemStatus = .active, needsReview: Bool = false, date: Date? = SearchFixture.date(13), context: String? = nil) -> ItemHit {
        ItemHit(id: id, kind: kind, title: MarkedText(title, terms: SearchQuery(text: "cafe").terms), date: date, contextID: context, status: status,
                needsReview: needsReview, matchedIn: matchedIn, snippet: nil)
    }

    private func results(_ items: [ItemHit] = [], moreItems: Bool = false, waiting: Int = 0) -> SearchResults {
        SearchResults(items: items, captures: [], moreItems: moreItems, moreCaptures: false, waitingToBeAnalysed: waiting)
    }

    @Test func anItemRowIsSpokenWithItsKindTitleDateAndWhereItMatched() {
        let text = SearchPanelModel.rowText(item(matchedIn: .alias), contextName: "Customer A", timezone: utc, locale: english)
        #expect(text == "Appointment, Café - Pruebas, Tue 13 Oct 2026 10:00, Customer A, matched in alias")
        #expect(SearchPanelModel.rowText(item(), contextName: nil, timezone: utc, locale: english) == "Appointment, Café - Pruebas, Tue 13 Oct 2026 10:00")
    }

    @Test func aRowSaysWhenTheItemIsDismissedOrNeedsReviewOrHasNoDate() {
        let dismissed = SearchPanelModel.rowText(item(kind: .task, status: .dismissed, date: nil), contextName: nil, timezone: utc, locale: english)
        #expect(dismissed == "Task, Café - Pruebas, dismissed")
        let review = SearchPanelModel.rowText(item(kind: .deadline, needsReview: true), contextName: nil, timezone: utc, locale: english)
        #expect(review.hasPrefix("Deadline, ") && review.hasSuffix(", needs review"))
        #expect(SearchPanelModel.rowText(item(kind: .reminder, matchedIn: .notes), contextName: nil, timezone: utc, locale: english).hasSuffix("matched in notes"))
    }

    @Test func theMessageSaysWhatToDoWhenThereAreNoResults() {
        let query = SearchQuery(text: "zzz")
        #expect(SearchPanelModel.message(for: SearchQuery(text: "a"), results: .empty, state: .ready, contextName: nil) == "Type at least two letters")
        #expect(SearchPanelModel.message(for: query, results: .empty, state: .ready, contextName: nil) == "Nothing found")
        #expect(SearchPanelModel.message(for: query, results: results([item()]), state: .ready, contextName: nil) == nil)
        #expect(SearchPanelModel.message(for: query, results: .empty, state: .preparing(done: 40, total: 200), contextName: nil) == "Search is being prepared (40 of 200)")
        #expect(SearchPanelModel.message(for: query, results: results(waiting: 3), state: .ready, contextName: nil) == "Nothing found. 3 captures are still waiting to be analysed.")
        #expect(SearchPanelModel.message(for: query, results: results(waiting: 1), state: .ready, contextName: nil) == "Nothing found. 1 capture is still waiting to be analysed.")
    }

    @Test func rowsListItemsThenAShowMoreRowAndTheKeyboardStaysInsideThem() {
        let all = results([item("a"), item("b")], moreItems: true)
        let rows = SearchPanelModel.rows(all)
        #expect(rows == [.item("a"), .item("b"), .showMoreItems])
        #expect(SearchPanelModel.move(from: nil, by: 1, count: rows.count) == 0)
        #expect(SearchPanelModel.move(from: 0, by: -1, count: rows.count) == 0)
        #expect(SearchPanelModel.move(from: 2, by: 1, count: rows.count) == 2)
        #expect(SearchPanelModel.move(from: 1, by: 1, count: rows.count) == 2)
        #expect(SearchPanelModel.move(from: nil, by: 1, count: 0) == nil)
        #expect(SearchPanelModel.target(rows: rows, selection: 1) == .openItem("b"))
        #expect(SearchPanelModel.target(rows: rows, selection: 2) == .showMoreItems)
        #expect(SearchPanelModel.target(rows: rows, selection: nil) == nil)
    }
}

@Suite struct SearchCaptureModelTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")
    private let terms = SearchQuery(text: "invoice").terms

    private func hit(app: String? = "Mail", title: String? = "Inbox", display: String? = "Built-in", first: String = "Invoice 2291 due") -> CaptureHit {
        CaptureHit(id: "img", capturedAt: SearchFixture.date(13), displayName: display, windowApp: app, windowTitle: title,
                   lines: [LineHit(number: 1, text: MarkedText(first, terms: terms))])
    }

    @Test func aCaptureRowIsSpokenWithTimeDisplayWindowAndFirstLine() {
        #expect(SearchPanelModel.rowText(hit(), timezone: utc, locale: english) == "Capture, Tue 13 Oct 2026 10:00, Built-in, Mail — Inbox, Invoice 2291 due")
        #expect(SearchPanelModel.rowText(hit(app: "Mail", title: nil, display: nil), timezone: utc, locale: english) == "Capture, Tue 13 Oct 2026 10:00, Mail, Invoice 2291 due")
        #expect(SearchPanelModel.rowText(hit(app: nil, title: nil), timezone: utc, locale: english) == "Capture, Tue 13 Oct 2026 10:00, Built-in, Invoice 2291 due")
    }

    @Test func theWindowTextNamesTheApplicationAndTheTitle() {
        #expect(SearchPanelModel.windowText(app: "Mail", title: "Inbox") == "Mail — Inbox")
        #expect(SearchPanelModel.windowText(app: "Mail", title: " ") == "Mail")
        #expect(SearchPanelModel.windowText(app: nil, title: "Inbox") == "Inbox")
        #expect(SearchPanelModel.windowText(app: nil, title: nil) == nil)
    }

    @Test func rowsListCapturesAfterItemsWithTheirOwnShowMore() {
        let results = SearchResults(items: [], captures: [hit()], moreItems: false, moreCaptures: true, waitingToBeAnalysed: 0)
        let rows = SearchPanelModel.rows(results)
        #expect(rows == [.capture("img"), .showMoreCaptures])
        #expect(SearchPanelModel.target(rows: rows, selection: 0) == .openCapture("img"))
        #expect(SearchPanelModel.target(rows: rows, selection: 1) == .showMoreCaptures)
    }

    @Test func theViewerListsAllLinesWithTheMatchesMarkedAndSaysWhenThePictureIsGone() {
        let lines = [RecognisedLine(n: 1, text: "Invoice 2291", box: PixelBox(x: 0, y: 0, width: 10, height: 10), confidence: 0.9),
                     RecognisedLine(n: 2, text: "nothing", box: PixelBox(x: 0, y: 20, width: 10, height: 10), confidence: 0.9),
                     RecognisedLine(n: 3, text: "invoice again", box: PixelBox(x: 0, y: 40, width: 10, height: 10), confidence: 0.9)]
        let stored = CaptureViewerModel(lines: lines, query: SearchQuery(text: "invoice"), pictureStored: true)
        #expect(stored.textLines.map(\.number) == [1, 2, 3])
        #expect(stored.matchingNumbers == [1, 3] && stored.note == nil && stored.heading == "2 matching lines")
        #expect(stored.textLines[1].text.marks.isEmpty && stored.textLines[0].text.marks.count == 1)
        let gone = CaptureViewerModel(lines: lines, query: SearchQuery(text: "2291"), pictureStored: false)
        #expect(gone.note == "The capture is no longer stored." && gone.heading == "1 matching line" && gone.matchingNumbers == [1])
        #expect(CaptureViewerModel(lines: lines, query: SearchQuery(text: "zzz"), pictureStored: true).heading == "No matching lines")
    }
}

@Suite struct SearchFilterTextTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func texts(_ query: SearchQuery, context: String? = nil) -> [String] {
        SearchPanelModel.filterTexts(query, contextName: context, timezone: utc, locale: english)
    }

    @Test func eachActiveFilterIsNamedInAFixedOrder() {
        #expect(texts(SearchQuery(text: "x")) == [])
        #expect(texts(SearchQuery(text: "x", kinds: [.tasks, .appointments])) == ["Kind: Appointments, Tasks"])
        #expect(texts(SearchQuery(text: "x", kinds: [.captures, .reminders])) == ["Kind: Reminders, Captures"])
        #expect(texts(SearchQuery(text: "x", context: .one("a")), context: "Customer A") == ["Context: Customer A"])
        #expect(texts(SearchQuery(text: "x", context: .none)) == ["No context"])
        let range = SearchFixture.date(1, hour: 0)...SearchFixture.date(31, hour: 23)
        #expect(texts(SearchQuery(text: "x", dates: range)) == ["Dates: 1 Oct – 31 Oct"])
        #expect(texts(SearchQuery(text: "x", includeDismissed: true)) == ["Including dismissed"])
        let all = SearchQuery(text: "x", kinds: [.tasks], context: .none, dates: range, includeDismissed: true)
        #expect(texts(all) == ["Kind: Tasks", "No context", "Dates: 1 Oct – 31 Oct", "Including dismissed"])
    }

    @Test func theEmptyMessageNamesTheFiltersThatAreOn() {
        let query = SearchQuery(text: "zzz", kinds: [.tasks], context: .none)
        let message = SearchPanelModel.message(for: query, results: .empty, state: .ready, contextName: nil)
        #expect(message == "Nothing found with Kind: Tasks, No context.")
        let waiting = SearchResults(items: [], captures: [], moreItems: false, moreCaptures: false, waitingToBeAnalysed: 2)
        #expect(SearchPanelModel.message(for: query, results: waiting, state: .ready, contextName: nil)
                == "Nothing found with Kind: Tasks, No context. 2 captures are still waiting to be analysed.")
    }

    @Test func clearingFiltersLeavesTheTextAndNothingElse() {
        var query = SearchQuery(text: "zzz", kinds: [.tasks], context: .none, dates: SearchFixture.date(1)...SearchFixture.date(2), includeDismissed: true)
        #expect(query.hasFilters)
        query.clearFilters()
        #expect(query == SearchQuery(text: "zzz") && !query.hasFilters)
        var kinds = SearchQuery(text: "q", kinds: [.tasks, .reminders])
        kinds.kinds.remove(.tasks)                      // clearing one filter keeps the rest
        #expect(kinds.kinds == [.reminders])
    }
}

@Suite struct SearchDatePresetTests {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let now = SearchFixture.date(15, hour: 14)

    @Test func presetsGiveWholeDayRangesAroundNow() {
        let today = SearchPanelModel.DatePreset.today.range(now: now, calendar: calendar)
        #expect(today.lowerBound == SearchFixture.date(15, hour: 0) && today.upperBound > SearchFixture.date(15, hour: 23) && today.upperBound < SearchFixture.date(16, hour: 0))
        let week = SearchPanelModel.DatePreset.last7Days.range(now: now, calendar: calendar)
        #expect(week.lowerBound == SearchFixture.date(9, hour: 0) && week.contains(now))
        let month = SearchPanelModel.DatePreset.thisMonth.range(now: now, calendar: calendar)
        #expect(month.lowerBound == SearchFixture.date(1, hour: 0) && month.contains(SearchFixture.date(31, hour: 12)) && !month.contains(SearchFixture.date(1, month: 11, hour: 1)))
        let next = SearchPanelModel.DatePreset.next30Days.range(now: now, calendar: calendar)
        #expect(next.lowerBound == SearchFixture.date(15, hour: 0) && next.contains(SearchFixture.date(14, month: 11)) && !next.contains(SearchFixture.date(16, month: 11)))
    }

    @Test func customRangesAreWholeDaysAndNeverBackwards() {
        let range = SearchPanelModel.customRange(from: SearchFixture.date(20, hour: 9), to: SearchFixture.date(10, hour: 18), calendar: calendar)
        #expect(range.lowerBound == SearchFixture.date(10, hour: 0) && range.upperBound > SearchFixture.date(20, hour: 23))        // swapped, widened to whole days
    }
}
