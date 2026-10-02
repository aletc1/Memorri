import Foundation
import OSLog
import Testing
@testable import MemorriCore

/// Search never writes what was typed or what was found to the log; only counts and times (spec 007, FR-014, SC-007).
@Suite struct SearchLoggingTests {
    @Test func aSearchRunLogsOnlyNumbers() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Zebracrossing planning", notes: "secretnotes", place: "Hiddenplace", people: ["Persontoken"], aliases: ["Aliastoken"])
        let started = Date()
        for text in ["zebracrossing", "secretnotes", "hiddenplace persontoken", "aliastoken", "\"zebracrossing planning\"", "nothingfound"] {
            _ = try await f.service.search(SearchQuery(text: text))
            _ = try await f.service.itemIDs(matching: SearchQuery(text: text))
        }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == MemorriCore.subsystem && $0.category == "search" }
        #expect(entries.count >= 6)
        let numbers = try Regex(#"^search (items=\d+ captures=\d+|index prepare done=\d+ total=\d+) ms=\d+$"#)       // tests run side by side: any search line may show up
        for entry in entries {
            #expect(entry.composedMessage.wholeMatch(of: numbers) != nil, "unexpected log text")
            for secret in ["zebracrossing", "secretnotes", "hiddenplace", "persontoken", "aliastoken", "nothingfound"] {
                #expect(!entry.composedMessage.lowercased().contains(secret))
            }
        }
    }

    @Test func prepareLogsOnlyNumbers() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Zebracrossing planning")
        try await f.database.pool.write { try $0.execute(sql: "DELETE FROM search_meta") }
        let started = Date()
        try await SearchIndex(database: f.database).prepare { _ in }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == MemorriCore.subsystem && $0.category == "search" }
        #expect(!entries.isEmpty)
        let numbers = try Regex(#"^search (items=\d+ captures=\d+|index prepare done=\d+ total=\d+) ms=\d+$"#)
        for entry in entries { #expect(entry.composedMessage.wholeMatch(of: numbers) != nil && !entry.composedMessage.lowercased().contains("zebra")) }
    }
}

/// An open panel stays current: the service says when what search reads changes (spec 007, task T030).
@Suite struct SearchChangesTests {
    @Test func aChangeToItemsAliasesOrTextFiresTheStream() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        let service = f.service
        let fired = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            group.addTask {
                var count = 0
                for await _ in service.changes() { count += 1; if count == 3 { break } }      // the first is the starting state
                return count
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); return -1 }
            try await Task.sleep(for: .milliseconds(300))
            try f.addItem("a", title: "Daily standup", aliases: ["Standup"])
            try await Task.sleep(for: .milliseconds(300))
            try await f.database.pool.write { try $0.execute(sql: "UPDATE items SET title = 'Team sync' WHERE id = 'a'") }
            let first = try await group.next() ?? -2
            group.cancelAll()
            return first
        }
        #expect(fired == 3)
    }
}
