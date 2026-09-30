import Foundation
import GRDB

public struct CaptureEventRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "capture_events"

    public var id: String
    public var capturedAt: Date
    public var trigger: String
    public var status: String
    public var failureReason: String?
    public var displayCount: Int

    public init(id: String, capturedAt: Date, trigger: String, status: String,
                failureReason: String?, displayCount: Int) {
        self.id = id
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.status = status
        self.failureReason = failureReason
        self.displayCount = displayCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case trigger, status
        case failureReason = "failure_reason"
        case displayCount = "display_count"
    }
}

public struct CaptureImageRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "capture_images"

    public var id: String
    public var eventId: String
    public var displayId: Int
    public var displayName: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var fullPath: String
    public var modelPath: String
    public var modelWidth: Int
    public var modelHeight: Int
    public var fullBytes: Int
    public var modelBytes: Int
    public var missing: Bool

    public init(id: String, eventId: String, displayId: Int, displayName: String?, pixelWidth: Int,
                pixelHeight: Int, scale: Double, fullPath: String, modelPath: String, modelWidth: Int,
                modelHeight: Int, fullBytes: Int, modelBytes: Int, missing: Bool) {
        self.id = id
        self.eventId = eventId
        self.displayId = displayId
        self.displayName = displayName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.fullPath = fullPath
        self.modelPath = modelPath
        self.modelWidth = modelWidth
        self.modelHeight = modelHeight
        self.fullBytes = fullBytes
        self.modelBytes = modelBytes
        self.missing = missing
    }

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case displayId = "display_id"
        case displayName = "display_name"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case scale
        case fullPath = "full_path"
        case modelPath = "model_path"
        case modelWidth = "model_width"
        case modelHeight = "model_height"
        case fullBytes = "full_bytes"
        case modelBytes = "model_bytes"
        case missing
    }
}

/// The part of the store the capture pipeline needs, so tests can fake a failing store.
public protocol CaptureStoring: Sendable {
    func insert(event: CaptureEventRecord, images: [CaptureImageRecord]) throws
}

public struct CaptureStore: CaptureStoring {
    let database: StorageDatabase

    public init(database: StorageDatabase) {
        self.database = database
    }

    /// Event and images in one transaction.
    public func insert(event: CaptureEventRecord, images: [CaptureImageRecord]) throws {
        try database.pool.write { db in
            try event.insert(db)
            for image in images { try image.insert(db) }
        }
    }

    /// Events strictly older than `cutoff`, oldest first. `nil` returns every event.
    public func events(olderThan cutoff: Date?) throws -> [CaptureEventRecord] {
        try database.pool.read { db in
            var request = CaptureEventRecord.order(Column("captured_at"))
            if let cutoff { request = request.filter(Column("captured_at") < cutoff) }
            return try request.fetchAll(db)
        }
    }

    public func deleteEvents(ids: [String]) throws {
        try database.pool.write { db in
            _ = try CaptureEventRecord.deleteAll(db, keys: ids)
        }
    }

    public func count() throws -> Int {
        try database.pool.read { try CaptureEventRecord.fetchCount($0) }
    }

    public func markMissing(imageID: String) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE capture_images SET missing = 1 WHERE id = ?", arguments: [imageID])
        }
    }

    public func allImages() throws -> [CaptureImageRecord] {
        try database.pool.read { try CaptureImageRecord.fetchAll($0) }
    }
}
