import Foundation

/// The meaning judge the app uses: it builds the Ollama-backed judge from the settings and the installed models, and builds it
/// again when the choice or the address changes or a minute has passed (a model may have been installed or removed).
public final class LiveMeaningJudge: MeaningJudging, @unchecked Sendable {
    private static let refreshAfter: TimeInterval = 60

    private let service: OllamaService
    private let settings: OllamaSettings
    private let database: StorageDatabase?
    private let time: any TimeSource
    private let lock = NSLock()
    private var cached: (key: String, at: Date, judge: OllamaMeaningJudge?)?

    public init(service: OllamaService, settings: OllamaSettings, database: StorageDatabase?, time: any TimeSource) {
        self.service = service; self.settings = settings; self.database = database; self.time = time
    }

    public var canEmbed: Bool { get async { await judge()?.canEmbed ?? false } }
    public var canJudge: Bool { get async { await judge()?.canJudge ?? false } }

    public func embeddings(for titles: [String]) async throws -> [[Float]] {
        guard let judge = await judge() else { throw MeaningJudgeError.unavailable }
        return try await judge.embeddings(for: titles)
    }

    public func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double {
        guard let judge = await judge() else { throw MeaningJudgeError.unavailable }
        return try await judge.sameEvent(a, b)
    }

    private func judge() async -> OllamaMeaningJudge? {
        let key = "\(settings.address.text)|\(settings.embeddingChoice)|\(settings.rerankerChoice)"
        let now = time.now()
        if let hit = lock.withLock({ cached }), hit.key == key, now.timeIntervalSince(hit.at) < Self.refreshAfter { return hit.judge }
        let client = await service.client()
        guard let installed = try? await client.models() else {
            lock.withLock { cached = (key, now, nil) }
            return nil
        }
        let names = Set(installed.map(\.name))
        let built = OllamaMeaningJudge(client: client, embeddingModel: settings.embeddingModel(installed: names),
                                       rerankerModel: settings.rerankerModel(installed: names), database: database)
        lock.withLock { cached = (key, now, built) }
        return built
    }
}
