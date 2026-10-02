import Foundation
import GRDB

/// One local notice: how many items are new, how many of them need review and how many became possibly cancelled.
public struct Notice: Sendable, Equatable {
    public let newItems: Int
    public let needReview: Int
    public let possiblyCancelled: Int

    public init(newItems: Int, needReview: Int, possiblyCancelled: Int) { self.newItems = newItems; self.needReview = needReview; self.possiblyCancelled = possiblyCancelled }

    public var text: String { NotificationWords.text(new: newItems, needReview: needReview, cancelled: possiblyCancelled) }
    /// A click opens the Inbox when something needs review, else all items.
    public var opensInbox: Bool { needReview > 0 || possiblyCancelled > 0 }
}

/// What the app does with a notice (the real centre, or a fake in tests).
public protocol NoticeShowing: Sendable {
    func show(_ notice: Notice) async
}

/// What the analysis job tells the notifier after a first analysis.
public protocol NewItemsNoting: Sendable {
    func itemsCreated(_ ids: [String]) async
    func itemsFlagged(_ ids: [String]) async
}

/// Groups the items a burst of captures creates into one notice, shown once things have been quiet for a while (spec 010, research R4). The counts are
/// read when the notice is due, so items merged, dismissed or approved meanwhile are counted as they are then.
public actor NewItemsNotifier: NewItemsNoting {
    private let database: StorageDatabase
    private let quiet: Duration
    private let ceiling: Duration
    private let enabled: @Sendable () -> Bool
    private let shower: any NoticeShowing
    private var created: Set<String> = []
    private var flagged: Set<String> = []
    private var firstAt: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    public init(database: StorageDatabase, quiet: Duration = .seconds(20), ceiling: Duration = .seconds(120), enabled: @escaping @Sendable () -> Bool,
                shower: any NoticeShowing) {
        self.database = database; self.quiet = quiet; self.ceiling = ceiling; self.enabled = enabled; self.shower = shower
    }

    public func itemsCreated(_ ids: [String]) { add(created: ids, flagged: []) }
    public func itemsFlagged(_ ids: [String]) { add(created: [], flagged: ids) }

    private func add(created ids: [String], flagged more: [String]) {
        guard enabled(), !(ids.isEmpty && more.isEmpty) else { return }
        created.formUnion(ids); flagged.formUnion(more)
        let now = ContinuousClock.now
        let start = firstAt ?? now
        firstAt = start
        // Wait for a quiet period, but never past the ceiling counted from the first item of the burst.
        let remaining = ceiling - start.duration(to: now)
        let wait = min(quiet, max(.zero, remaining))
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    /// Shows the notice for what has gathered, if there is anything to say.
    func fire() async {
        let ids = created, flaggedIDs = flagged
        created = []; flagged = []; firstAt = nil; timer = nil
        guard enabled() else { return }
        let notice = try? await database.pool.read { db -> Notice in
            func active(_ ids: Set<String>, reviewOnly: Bool) throws -> Int {
                guard !ids.isEmpty else { return 0 }
                let marks = ids.map { _ in "?" }.joined(separator: ", ")
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE status = 'active' AND id IN (\(marks))\(reviewOnly ? " AND needs_review = 1" : "")",
                                        arguments: StatementArguments(Array(ids))) ?? 0
            }
            let cancelled = try flaggedIDs.isEmpty ? 0 : Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM items WHERE status = 'active' AND review_reasons_json LIKE '%possibly-cancelled%' AND id IN (\(flaggedIDs.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments(Array(flaggedIDs))) ?? 0
            return Notice(newItems: try active(ids, reviewOnly: false), needReview: try active(ids, reviewOnly: true), possiblyCancelled: cancelled)
        }
        guard let notice, !notice.text.isEmpty else { return }
        await shower.show(notice)
    }
}
