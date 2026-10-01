import Foundation
import Testing
@testable import MemorriCore

@Suite struct FieldResolverTests {
    private func at(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 1_791_900_000 + Double(minutes) * 60) }

    private func obs(_ id: String, _ field: ItemField, _ value: JSONValue, _ source: ObservationSource = .read, _ confidence: Double = 0.8,
                     sighting: String? = nil, seen: Int = 0) -> ItemObservation {
        ItemObservation(id: id, itemID: "i", sightingID: sighting ?? (source == .user ? nil : "s-\(id)"), field: field, value: value,
                    source: source, confidence: confidence, observedAt: at(seen))
    }

    private func resolve(_ observations: [ItemObservation], locks: [ItemField: String] = [:]) -> ResolvedFields {
        FieldResolver.resolve(observations, locks: locks)
    }

    @Test func aLockedUserValueBeatsEverything() {
        let observations = [obs("a", .title, .string("Daily standup"), .read, 0.99, seen: 5),
                            obs("u", .title, .string("My title"), .user, 1, seen: 1)]
        let resolved = resolve(observations, locks: [.title: "u"])
        #expect(resolved.values[.title] == .string("My title"))
        #expect(resolved.chosen[.title] == "u")
        #expect(resolved.aliases == ["Daily standup"])
    }

    @Test func anUnlockedUserObservationIsOnlyHistory() {
        let observations = [obs("a", .title, .string("Daily standup")), obs("u", .title, .string("My title"), .user, 1, seen: 9)]
        #expect(resolve(observations).values[.title] == .string("Daily standup"))
    }

    @Test func readBeatsInferredWhateverTheConfidence() {
        let observations = [obs("g", .end, .date(at(60)), .inferred, 0.99, seen: 5), obs("r", .end, .date(at(45)), .read, 0.3, seen: 1)]
        let resolved = resolve(observations)
        #expect(resolved.values[.end] == .date(at(45)))
        #expect(resolved.chosen[.end] == "r")
    }

    @Test func higherConfidenceWinsWhenTheGapIsAtLeastATenth() {
        let observations = [obs("low", .place, .string("Room 4"), .read, 0.5, seen: 9), obs("high", .place, .string("Room 7"), .read, 0.8, seen: 1)]
        #expect(resolve(observations).values[.place] == .string("Room 7"))
    }

    @Test func confidenceWithinATenthIsEqualAndTheMoreRecentWins() {
        let observations = [obs("old", .place, .string("Room 4"), .read, 0.85, seen: 1), obs("new", .place, .string("Room 7"), .read, 0.8, seen: 9)]
        let resolved = resolve(observations)
        #expect(resolved.values[.place] == .string("Room 7"))
        #expect(resolved.chosen[.place] == "new")
    }

    @Test func aTitleThatAnotherIsATruncationOfLosesToTheLongerOne() {
        let observations = [obs("full", .title, .string("Quarterly planning with the customer"), .read, 0.7, seen: 1),
                            obs("cut", .title, .string("Quarterly planning with the cust…"), .read, 0.75, seen: 9)]
        let resolved = resolve(observations)
        #expect(resolved.values[.title] == .string("Quarterly planning with the customer"))
        #expect(resolved.aliases == ["Quarterly planning with the cust…"])
    }

    @Test func aTimedStartBeatsAnAllDayOne() {
        let observations = [obs("d1", .start, .date(at(0)), .read, 0.9, sighting: "all-day", seen: 9),
                            obs("d2", .allDay, .bool(true), .read, 0.9, sighting: "all-day", seen: 9),
                            obs("t1", .start, .date(at(600)), .read, 0.8, sighting: "timed", seen: 1),
                            obs("t2", .allDay, .bool(false), .read, 0.8, sighting: "timed", seen: 1)]
        let resolved = resolve(observations)
        #expect(resolved.values[.start] == .date(at(600)))
        #expect(resolved.values[.allDay] == .bool(false))
    }

    @Test func peopleAreTheUnionInFirstSeenOrder() {
        let observations = [obs("p2", .people, .array([.string("Ben"), .string("anna")]), .read, 0.8, seen: 9),
                            obs("p1", .people, .array([.string("Anna"), .string("Carl")]), .read, 0.8, seen: 1)]
        #expect(resolve(observations).values[.people] == .array([.string("Anna"), .string("Carl"), .string("Ben")]))
    }

    @Test func aFieldWithNoObservationsIsAbsent() {
        let resolved = resolve([obs("a", .title, .string("Daily standup"))])
        #expect(resolved.values[.end] == nil && resolved.chosen[.end] == nil)
        #expect(resolve([]).values.isEmpty)
    }

    @Test func nullValuesAreIgnored() {
        let resolved = resolve([obs("n", .end, .null, .read, 0.99, seen: 9), obs("a", .end, .date(at(30)), .read, 0.5, seen: 1)])
        #expect(resolved.values[.end] == .date(at(30)))
    }

    @Test func aliasesAreDistinctNormalisedAndNeverTheChosenTitle() {
        let observations = [obs("a", .title, .string("Daily Standup"), .read, 0.9, seen: 1),
                            obs("b", .title, .string("daily standup!"), .read, 0.8, seen: 2),
                            obs("c", .title, .string("Reunión diaria"), .read, 0.8, seen: 3),
                            obs("d", .title, .string("Reunión diaria…"), .read, 0.8, seen: 4)]
        let resolved = resolve(observations)
        #expect(resolved.values[.title] == .string("Daily Standup"))
        #expect(resolved.aliases == ["Reunión diaria"])
    }
}
