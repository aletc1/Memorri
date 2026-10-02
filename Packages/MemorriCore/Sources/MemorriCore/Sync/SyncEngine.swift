import Foundation
import GRDB
import os

/// Why a sync could not run at all.
public enum SyncProblem: Sendable, Equatable {
    case noAccess(SyncEntryKind)
    /// The chosen calendar or list no longer exists.
    case targetGone(SyncEntryKind)
    /// Neither a calendar nor a list is chosen.
    case notSetUp
}

public struct SyncOutcome: Sendable, Equatable {
    public let plan: SyncPlan
    public let run: SyncRunRecord
    public let problem: SyncProblem?
}

/// Runs a plan against the system store, always through the scoped store (ADR 0026): it writes only in the chosen calendar and list, only
/// entries it made, and records every entry in `sync_links`. A preview makes the plan and writes nothing.
public struct SyncEngine: Sendable {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "sync")

    let database: StorageDatabase
    let store: SyncStore
    let events: any EventStoring
    let operations: ItemOperations
    let now: @Sendable () -> Date

    public init(database: StorageDatabase, store: SyncStore, events: any EventStoring, operations: ItemOperations, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.store = store; self.events = events; self.operations = operations; self.now = now
    }

    // MARK: Entry points

    public func preview() async -> SyncOutcome { await go(preview: true, allowMove: false) }

    /// `allowMove` is true once the user confirmed moving Memorri's entries to a newly chosen calendar or list (FR-020).
    public func run(allowMove: Bool = false) async -> SyncOutcome { await go(preview: false, allowMove: allowMove) }

    /// Switching sync off with `Remove Memorri's entries` (FR-017): deletes every entry Memorri made that is still there, through the scoped store (only
    /// entries in `sync_links` can go), and marks the links removed so switching on again writes them afresh. Returns how many were removed.
    @discardableResult
    public func removeAllEntries() -> Int {
        let links = (try? store.links()) ?? [:]
        let settings = store.syncSettings(now: now())
        let scoped = ScopedEventStore(base: events, calendarID: settings.calendarID, listID: settings.listID,
                                      alsoRemovableFrom: Set(links.values.map(\.containerID)), isOurs: { [store] in store.isLinked(ekID: $0) })
        var removed = 0
        let date = now()
        for var link in links.values where [.synced, .completed, .failed].contains(link.state) {
            guard scoped.entry(id: link.ekID, kind: link.kind) != nil else { continue }
            do { try scoped.delete(id: link.ekID, kind: link.kind) } catch { continue }
            link.state = .removed; link.failure = nil; link.syncedAt = date
            try? store.save(link, at: date)
            removed += 1
        }
        Self.logger.info("removed \(removed) entries on switching off")
        return removed
    }

    // MARK: Reading what sync needs

    /// The items sync has to consider: those with a link (whatever became of them) and those that are ready.
    func sources() throws -> [SyncSource] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.*, (SELECT c.name FROM contexts c WHERE c.id = i.context_id) AS context_name
                FROM items i
                WHERE i.id IN (SELECT item_id FROM sync_links) OR (i.status = 'active' AND i.needs_review = 0)
                ORDER BY i.first_seen, i.id
                """)
            return try rows.compactMap { row in
                guard let item = ItemStore.item(from: row) else { return nil }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: item.timezone) ?? TimeZone(identifier: "UTC")
                formatter.dateFormat = "d MMM HH:mm"
                let evidence = try Row.fetchAll(db, sql: """
                    SELECT captured_at, window_app, window_title FROM sightings WHERE item_id = ? ORDER BY captured_at DESC, id LIMIT ?
                    """, arguments: [item.id, SyncRender.evidenceLines]).map { sighting -> String in
                    let when = formatter.string(from: sighting["captured_at"])
                    let app = (sighting["window_app"] as String?) ?? "", title = (sighting["window_title"] as String?) ?? ""
                    let window = [app, title].filter { !$0.isEmpty }.joined(separator: " — ")
                    return window.isEmpty ? when : "\(when) · \(window)"
                }
                return SyncSource(item: item, contextName: row["context_name"], evidence: evidence)
            }
        }
    }

    // MARK: The run

    private func go(preview: Bool, allowMove: Bool) async -> SyncOutcome {
        let started = now()
        var run = SyncRunRecord(startedAt: started, finishedAt: started, preview: preview)
        let settings = store.syncSettings(now: started)

        func finish(_ plan: SyncPlan, _ problem: SyncProblem?) -> SyncOutcome {
            run = SyncRunRecord(id: run.id, startedAt: started, finishedAt: now(), preview: preview).copying(from: run)
            try? store.record(run)
            Self.logger.info("sync preview=\(preview) created=\(run.created) updated=\(run.updated) removed=\(run.removed) adopted=\(run.adopted) skipped=\(run.skipped) failed=\(run.failed) problem=\(problem == nil ? "none" : "yes", privacy: .public)")
            return SyncOutcome(plan: plan, run: run, problem: problem)
        }

        if let problem = check(settings) { return finish(SyncPlan(actions: []), problem) }

        let scoped = ScopedEventStore(base: events, calendarID: settings.calendarID, listID: settings.listID,
                                      alsoRemovableFrom: allowMove ? Set((try? store.links().values.map(\.containerID)) ?? []) : [],
                                      isOurs: { [store] in store.isLinked(ekID: $0) })
        var lastPlan = SyncPlan(actions: [])
        for pass in 0..<2 {
            let plan: SyncPlan
            do {
                let links = try store.links()
                plan = SyncPlanner.plan(sources: try sources(), links: links, lookup: { scoped.entry(id: $0.ekID, kind: $0.kind) }, settings: settings)
            } catch {
                run.failed += 1; run.detail.append("could not read the library")
                return finish(lastPlan, nil)
            }
            if pass == 0 { lastPlan = plan }
            if preview { Self.count(plan, into: &run); return finish(plan, nil) }
            let adopted = await execute(plan, scoped: scoped, allowMove: allowMove, run: &run)
            // An edit adopted from Calendar changed the item; a second pass writes Memorri's rendering on top of it.
            if !adopted { break }
        }
        return finish(lastPlan, nil)
    }

    private func check(_ settings: SyncSettings) -> SyncProblem? {
        if settings.calendarID == nil && settings.listID == nil { return .notSetUp }
        for kind in [SyncEntryKind.event, .reminder] {
            guard let id = settings.containerID(for: kind) else { continue }
            if events.access(for: kind) != .allowed { return .noAccess(kind) }
            if !events.containerExists(id: id, kind: kind) { return .targetGone(kind) }
        }
        return nil
    }

    private static func count(_ plan: SyncPlan, into run: inout SyncRunRecord) {
        run.created += plan.created; run.updated += plan.updated; run.removed += plan.removed; run.adopted += plan.adopted
        run.skipped += plan.actions.filter { if case .skip(_, let reason) = $0 { [.noDate, .tooOld, .noCalendar, .noList].contains(reason) } else { false } }.count
    }

    /// Executes the plan; returns whether an outside edit was adopted (so another pass is due).
    private func execute(_ plan: SyncPlan, scoped: ScopedEventStore, allowMove: Bool, run: inout SyncRunRecord) async -> Bool {
        var adoptedAny = false
        let date = now()
        let links = (try? store.links()) ?? [:]
        for action in plan.actions {
            let short = String(action.itemID.prefix(8))
            do {
                switch action {
                case .create(let id, let entry, let container):
                    let ekID = try scoped.create(entry, in: container)
                    // The baseline for spotting outside edits is what the store holds now: it may keep a field a little differently than written.
                    let held = scoped.entry(id: ekID, kind: entry.kind)?.entry ?? entry
                    try store.save(SyncLink(itemID: id, kind: entry.kind, ekID: ekID, containerID: container, hash: SyncRender.hash(entry),
                                            hashVersion: SyncRender.hashVersion, fields: held, state: .synced, syncedAt: date), at: date)
                    run.created += 1
                case .update(let id, let entry, _):
                    guard var link = links[id] else { continue }
                    try scoped.update(id: link.ekID, entry)
                    link.hash = SyncRender.hash(entry); link.hashVersion = SyncRender.hashVersion
                    link.fields = scoped.entry(id: link.ekID, kind: link.kind)?.entry ?? entry
                    link.state = .synced; link.failure = nil; link.syncedAt = date
                    try store.save(link, at: date)
                    run.updated += 1
                case .move(let id, let entry, let from, let to):
                    guard var link = links[id] else { continue }
                    guard allowMove else { run.skipped += 1; run.detail.append("\(short): moving to the new \(entry.kind == .event ? "calendar" : "list") needs your confirmation"); continue }
                    let newID = try scoped.create(entry, in: to)
                    try scoped.delete(id: link.ekID, kind: link.kind)
                    _ = from
                    link.ekID = newID; link.containerID = to; link.hash = SyncRender.hash(entry); link.hashVersion = SyncRender.hashVersion
                    link.fields = scoped.entry(id: newID, kind: link.kind)?.entry ?? entry
                    link.state = .synced; link.failure = nil; link.syncedAt = date
                    try store.save(link, at: date)
                    run.updated += 1
                case .remove(let id, _):
                    guard var link = links[id] else { continue }
                    try scoped.delete(id: link.ekID, kind: link.kind)
                    link.state = .removed; link.failure = nil; link.syncedAt = date
                    try store.save(link, at: date)
                    run.removed += 1
                case .adopt(let id, let fields):
                    guard var link = links[id] else { continue }
                    for (field, value) in fields.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        do { _ = try operations.edit(id, field: field, value: value, source: link.kind == .event ? "Calendar" : "Reminders") }
                        catch { run.failed += 1; run.detail.append("\(short): \(field.rawValue) from Calendar was not accepted") }
                    }
                    if let stored = scoped.entry(id: link.ekID, kind: link.kind) { link.fields = stored.entry }
                    link.syncedAt = date
                    try store.save(link, at: date)
                    run.adopted += 1; adoptedAny = true
                case .complete(let id):
                    guard var link = links[id] else { continue }
                    link.state = .completed; link.syncedAt = date
                    try store.save(link, at: date)
                case .markRemovedByUser(let id, let reason):
                    guard var link = links[id] else { continue }
                    link.state = .removedByUser; link.failure = reason; link.syncedAt = date
                    try store.save(link, at: date)
                case .skip(_, let reason):
                    if [.noDate, .tooOld, .noCalendar, .noList].contains(reason) { run.skipped += 1 }
                }
            } catch {
                run.failed += 1
                let why = (error as? SyncError).map(Self.text) ?? "the store refused"
                run.detail.append("\(short): \(why)")
                if var link = links[action.itemID] { link.state = .failed; link.failure = why; try? store.save(link, at: date) }
            }
        }
        return adoptedAny
    }

    static func text(_ error: SyncError) -> String {
        switch error {
        case .outsideTarget: "the entry is not in the chosen calendar or list"
        case .noTarget(let kind): kind == .event ? "no calendar is chosen" : "no list is chosen"
        case .notOurs: "the entry was not made by Memorri"
        case .noAccess(let kind): kind == .event ? "no access to Calendar" : "no access to Reminders"
        case .failed(let why): why
        }
    }
}

extension SyncRunRecord {
    /// The same run with the counts and notes of `other`.
    func copying(from other: SyncRunRecord) -> SyncRunRecord {
        var copy = self
        copy.created = other.created; copy.updated = other.updated; copy.removed = other.removed; copy.adopted = other.adopted
        copy.skipped = other.skipped; copy.failed = other.failed; copy.detail = other.detail
        return copy
    }
}
