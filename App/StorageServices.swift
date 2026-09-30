import MemorriCore

/// What Settings needs from the storage: figures, clean-up, the two settings and retention.
struct StorageServices: Sendable {
    let stats: StorageStats
    let cleanup: CleanupService
    let settings: StorageSettings
    let retention: RetentionService
}
