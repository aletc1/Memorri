import Foundation

/// Decides which copy of the app keeps running when more than one is started: the oldest one.
///
/// Process IDs are not used to rank copies, because they wrap around on a busy Mac and a new
/// launch can get a lower PID than one that has been running for days. The PID only breaks a tie.
public enum SingleInstanceArbiter {
    public struct Instance: Sendable, Equatable {
        public let pid: Int32
        /// `nil` when the system does not know it yet; such a copy counts as the newest.
        public let launchDate: Date?

        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// - Parameters:
    ///   - own: this copy.
    ///   - others: running copies of the app; an entry with `own`'s PID is ignored.
    /// - Returns: `true` when another copy is older than this one.
    public static func shouldExit(own: Instance, others: [Instance]) -> Bool {
        others.contains { $0.pid != own.pid && isOlder($0, than: own) }
    }

    private static func isOlder(_ a: Instance, than b: Instance) -> Bool {
        switch (a.launchDate, b.launchDate) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.pid < b.pid          // same launch time, or both unknown
        }
    }
}
