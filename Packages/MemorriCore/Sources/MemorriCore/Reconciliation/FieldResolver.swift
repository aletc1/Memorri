import Foundation

/// The current value of each field of an item, the observation each came from and the other titles seen.
public struct ResolvedFields: Sendable, Equatable {
    public var values: [ItemField: JSONValue] = [:]
    public var chosen: [ItemField: String] = [:]
    /// Titles seen that are not the chosen title, one spelling per normalised form (the first seen).
    public var aliases: [String] = []
}

/// Chooses each field of an item from its observations (research R9): a locked user value; then read over inferred; then a
/// timed start or end over an all-day one; then the clearly higher confidence (a gap under 0.1 is a tie); then the more complete value; then the more recent sighting.
public enum FieldResolver {
    static let confidenceGap = 0.1

    public static func resolve(_ observations: [ItemObservation], locks: [ItemField: String]) -> ResolvedFields {
        var result = ResolvedFields()
        let byID = Dictionary(observations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allDayBySighting = Dictionary(observations.filter { $0.field == .allDay }.compactMap { o in
            o.sightingID.flatMap { id in o.value.asBool.map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })

        for field in ItemField.allCases {
            if let lock = locks[field], let observation = byID[lock], observation.value != .null {
                result.values[field] = observation.value
                result.chosen[field] = observation.id
                continue
            }
            // Newest first, so a tie keeps the more recent sighting. User values count only while locked.
            let candidates = observations.filter { $0.field == field && $0.source != .user && $0.value != .null }
                .sorted { $0.observedAt != $1.observedAt ? $0.observedAt > $1.observedAt : $0.id < $1.id }
            guard var best = candidates.first else { continue }
            if field == .people {
                result.values[field] = .array(peopleUnion(candidates).map(JSONValue.string))
                result.chosen[field] = best.id
                continue
            }
            for other in candidates.dropFirst() where isBetter(other, than: best, field: field, allDay: allDayBySighting) { best = other }
            result.values[field] = best.value
            result.chosen[field] = best.id
        }
        // The all-day flag follows the sighting the start came from, so a timed start is never labelled all-day.
        if locks[.allDay] == nil, let startID = result.chosen[.start], let sighting = byID[startID]?.sightingID, let flag = allDayBySighting[sighting] {
            result.values[.allDay] = .bool(flag)
        }

        if let title = result.values[.title]?.asString {
            let chosenForm = TitleNormaliser.normalise(title)
            var seen: Set<String> = [chosenForm]
            for observation in observations.filter({ $0.field == .title && $0.source != .user || ($0.field == .title && $0.id != result.chosen[.title]) })
                .sorted(by: { $0.observedAt != $1.observedAt ? $0.observedAt < $1.observedAt : $0.id < $1.id }) {
                guard let text = observation.value.asString else { continue }
                let form = TitleNormaliser.normalise(text)
                if form.isEmpty || !seen.insert(form).inserted { continue }
                result.aliases.append(text)
            }
        }
        return result
    }

    private static func peopleUnion(_ newestFirst: [ItemObservation]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for observation in newestFirst.reversed() {
            for name in observation.value.asStrings ?? [] {
                let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if seen.insert(key).inserted { names.append(name) }
            }
        }
        return names
    }

    private static func isBetter(_ a: ItemObservation, than b: ItemObservation, field: ItemField, allDay: [String: Bool]) -> Bool {
        let aRead = a.source == .read, bRead = b.source == .read
        if aRead != bRead { return aRead }
        // A time of day is more specific than "all day", whatever the confidence (edge case in the spec).
        if field == .start || field == .end {
            let aFlag = a.sightingID.flatMap { allDay[$0] }, bFlag = b.sightingID.flatMap { allDay[$0] }
            if aFlag == false && bFlag == true { return true }
            if aFlag == true && bFlag == false { return false }
        }
        if abs(a.confidence - b.confidence) >= confidenceGap - 1e-9 { return a.confidence > b.confidence }
        return isMoreComplete(a, than: b, field: field, allDay: allDay)
    }

    private static func isMoreComplete(_ a: ItemObservation, than b: ItemObservation, field: ItemField, allDay: [String: Bool]) -> Bool {
        switch field {
        case .title, .place, .notes:
            guard let x = a.value.asString, let y = b.value.asString else { return false }
            let nx = TitleNormaliser.normalise(x), ny = TitleNormaliser.normalise(y)
            return nx.count > ny.count && nx.hasPrefix(ny)
        case .start, .end:
            let aFlag = a.sightingID.flatMap { allDay[$0] }, bFlag = b.sightingID.flatMap { allDay[$0] }
            return aFlag == false && bFlag == true
        default:
            return false
        }
    }
}
