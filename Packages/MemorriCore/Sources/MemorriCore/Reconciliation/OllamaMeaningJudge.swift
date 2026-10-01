import Foundation
import GRDB

/// The local embedding model and reranker behind `MeaningJudging` (research R3 and R4). Vectors are cached per normalised title
/// and model in `title_embeddings`.
public final class OllamaMeaningJudge: MeaningJudging, @unchecked Sendable {
    public static let instructionVersion = "rerank-v2"
    private static let instruction = "Are these two entries the same event, only written differently (another language, shorter, or with extra words)? Two different topics at the same time are different events."
    private static let cacheLife: TimeInterval = 60

    private let client: OllamaClient
    private let embeddingModel: String?
    private let rerankerModel: String?
    private let database: StorageDatabase?
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var installed: (names: Set<String>, at: Date)?

    public init(client: OllamaClient, embeddingModel: String?, rerankerModel: String?, database: StorageDatabase?,
                timeout: TimeInterval = 20, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.embeddingModel = embeddingModel
        self.rerankerModel = rerankerModel
        self.database = database
        self.timeout = timeout
        self.now = now
    }

    public var canEmbed: Bool { get async { await isInstalled(embeddingModel) } }
    public var canJudge: Bool { get async { await isInstalled(rerankerModel) } }

    private func isInstalled(_ model: String?) async -> Bool {
        guard let model else { return false }
        let current = now()
        if let cached = withLock({ installed }), current.timeIntervalSince(cached.at) < Self.cacheLife { return cached.names.contains(model) }
        guard let models = try? await client.models() else { return false }
        let names = Set(models.map(\.name))
        withLock { installed = (names, current) }
        return names.contains(model)
    }

    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func embeddings(for titles: [String]) async throws -> [[Float]] {
        guard let model = embeddingModel, await canEmbed else { throw MeaningJudgeError.unavailable }
        var found = try cached(titles, model: model)
        let missing = titles.filter { found[$0] == nil }
        if !missing.isEmpty {
            let unique = Array(NSOrderedSet(array: missing)) as? [String] ?? missing
            let vectors = try await client.embed(model: model, inputs: unique.map { "query: \($0)" }, timeout: timeout)
            for (title, vector) in zip(unique, vectors) { found[title] = vector }
            try store(Dictionary(zip(unique, vectors), uniquingKeysWith: { first, _ in first }), model: model)
        }
        return titles.map { found[$0] ?? [] }
    }

    /// The probability that both entries are one event. The reranker is sensitive to which entry comes first, so both orders are
    /// asked and the lower probability counts (measured on the synthetic set, research R4).
    public func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double {
        guard let model = rerankerModel, await canJudge else { throw MeaningJudgeError.unavailable }
        let forward = try await yesProbability(model: model, a, b)
        let backward = try await yesProbability(model: model, b, a)
        return min(forward, backward)
    }

    private func yesProbability(model: String, _ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double {
        let top = try await client.generateNextTokenLogprobs(model: model, prompt: Self.prompt(a, b), timeout: timeout)
        var yes = 0.0, no = 0.0
        for entry in top {
            switch entry.token.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yes": yes += exp(entry.logprob)
            case "no": no += exp(entry.logprob)
            default: break
            }
        }
        guard yes + no > 0 else { throw MeaningJudgeError.badAnswer }
        return yes / (yes + no)
    }

    static func prompt(_ a: JudgedSighting, _ b: JudgedSighting) -> String {
        func line(_ s: JudgedSighting) -> String { ([s.title, s.when] + (s.context.map { [$0] } ?? [])).joined(separator: ", ") }
        return "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. "
            + "Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n"
            + "<|im_start|>user\n<Instruct>: \(instruction)\n<Query>: \(line(a))\n<Document>: \(line(b))<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    // MARK: Cache

    private func cached(_ titles: [String], model: String) throws -> [String: [Float]] {
        guard let database, !titles.isEmpty else { return [:] }
        return try database.pool.read { db in
            var result: [String: [Float]] = [:]
            for title in Set(titles) {
                if let data = try Data.fetchOne(db, sql: "SELECT vector FROM title_embeddings WHERE normalised = ? AND model = ?", arguments: [title, model]) {
                    result[title] = Self.decode(data)
                }
            }
            return result
        }
    }

    private func store(_ vectors: [String: [Float]], model: String) throws {
        guard let database, !vectors.isEmpty else { return }
        let date = now()
        try database.pool.write { db in
            for (title, vector) in vectors {
                try db.execute(sql: "INSERT OR REPLACE INTO title_embeddings (normalised, model, vector, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [title, model, Self.encode(vector), date])
            }
        }
    }

    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - 3, by: 4).map { offset in
            Float(bitPattern: UInt32(littleEndian: data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
    }
}
