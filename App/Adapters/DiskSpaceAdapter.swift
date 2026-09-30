import Foundation
import MemorriCore

/// Free space on the volume that holds the data folder (strictly free, not counting purgeable).
struct DiskSpaceAdapter: DiskSpaceChecking {
    func freeBytes(at url: URL) throws -> Int64 {
        #if DEBUG
        if let simulated = Self.simulatedFreeBytes { return simulated }
        #endif
        // The folder may not exist yet, so ask about the nearest folder that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = values.volumeAvailableCapacity else { throw CocoaError(.fileReadUnknown) }
        return Int64(free)
    }

    #if DEBUG
    /// `--simulate-free-bytes <n>` (Debug builds only) makes the check report n bytes.
    private static let simulatedFreeBytes: Int64? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--simulate-free-bytes"), index + 1 < arguments.count else { return nil }
        return Int64(arguments[index + 1])
    }()
    #endif
}
