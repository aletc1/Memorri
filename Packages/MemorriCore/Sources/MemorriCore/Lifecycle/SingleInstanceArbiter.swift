/// Decides which copy of the app keeps running when more than one is started at nearly the same
/// time: the copy with the lowest process ID stays, the others quit.
public enum SingleInstanceArbiter {
    /// - Parameters:
    ///   - ownPID: the process ID of this copy.
    ///   - otherPIDs: process IDs of running copies of the app; `ownPID` in the list is ignored.
    public static func shouldExit(ownPID: Int32, otherPIDs: [Int32]) -> Bool {
        otherPIDs.contains { $0 != ownPID && $0 < ownPID }
    }
}
