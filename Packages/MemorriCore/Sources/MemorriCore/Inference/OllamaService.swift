import Foundation
import os

/// What the last check found out about the server and the chosen model.
public enum ServerStatus: Sendable, Equatable {
    case unchecked
    case reachable(version: String)
    case notReachable
    case timedOut
    /// The server answers but no installed model can read images.
    case noVisionModel
    case noModelChosen
    /// The chosen model is not installed, or cannot read images.
    case modelMissing(String)

    /// The text shown in Settings (contracts/ui-contract.md).
    public var message: String {
        switch self {
        case .unchecked: "Not checked yet."
        case .reachable(let version): "Reachable, Ollama \(version)"
        case .notReachable: "Not reachable. Start Ollama and try again."
        case .timedOut: "No answer within 5 seconds."
        case .noVisionModel: "Ollama is running but no installed model can read images. Install a vision model."
        case .noModelChosen: "Choose a model."
        case .modelMissing(let name): "The model \(name) is not installed."
        }
    }

    /// True only when the server answers and the chosen model can be used.
    public var isUsable: Bool {
        if case .reachable = self { true } else { false }
    }

    /// Short name for the log (`check status=…`).
    var logName: String {
        switch self {
        case .unchecked: "unchecked"
        case .reachable: "reachable"
        case .notReachable: "notReachable"
        case .timedOut: "timedOut"
        case .noVisionModel: "noVisionModel"
        case .noModelChosen: "noModelChosen"
        case .modelMissing: "modelMissing"
        }
    }
}

/// The installed models the user can pick from.
public struct ModelList: Sendable, Equatable {
    /// Models that can read images, in the server's order.
    public let usable: [InstalledModel]
    /// Installed models left out because they cannot read images.
    public let hiddenCount: Int

    public init(usable: [InstalledModel], hiddenCount: Int) {
        self.usable = usable
        self.hiddenCount = hiddenCount
    }
}

/// Knows whether the server and the chosen model are usable. The settings screen, the queue and the
/// tests all ask this one place, so what the user sees and why the queue waits cannot disagree.
public actor OllamaService {
    /// The whole check has this long (FR-003).
    public static let checkTimeout: TimeInterval = 5

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "ollama")

    private let settings: OllamaSettings
    private let makeTransport: @Sendable (LoopbackAddress) -> any OllamaTransport
    private let time: any TimeSource
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public private(set) var status: ServerStatus = .unchecked
    private var inFlight: Task<ServerStatus, Never>?
    private var continuations: [UUID: AsyncStream<ServerStatus>.Continuation] = [:]

    public init(settings: OllamaSettings,
                makeTransport: @escaping @Sendable (LoopbackAddress) -> any OllamaTransport,
                time: any TimeSource = SystemTimeSource(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.settings = settings
        self.makeTransport = makeTransport
        self.time = time
        self.sleep = sleep
    }

    /// A client for the address in the settings right now.
    public func client() -> OllamaClient {
        OllamaClient(transport: makeTransport(settings.address))
    }

    /// The vision-capable installed models (FR-005). Throws when the server cannot be asked.
    public func modelList() async throws -> ModelList {
        let models = try await client().models()
        let usable = models.filter(\.readsImages)
        return ModelList(usable: usable, hiddenCount: models.count - usable.count)
    }

    /// Chooses the recommended model when nothing is chosen and it is installed (FR-006). Never
    /// replaces an existing choice and does not even ask the server when one exists.
    public func applyDefaultModelIfNeeded() async {
        guard settings.model == nil else { return }
        guard let list = try? await modelList(),
              list.usable.contains(where: { $0.name == OllamaSettings.recommendedModel }) else { return }
        // The user may have chosen while the server was answering.
        if settings.model == nil { settings.setModel(OllamaSettings.recommendedModel) }
    }

    /// Runs a check. One check runs at a time: a call made while one is running joins it (FR-004).
    @discardableResult
    public func check() async -> ServerStatus {
        if let running = inFlight { return await running.value }
        let task = Task { await self.runCheck() }
        inFlight = task
        return await task.value
    }

    /// Emits the current status first, then every change once.
    public func statusUpdates() -> AsyncStream<ServerStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ServerStatus.self)
        continuation.yield(status)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func runCheck() async -> ServerStatus {
        let started = time.now()
        let result = await evaluateWithinLimit()
        inFlight = nil
        publish(result)
        let elapsed = Int(time.now().timeIntervalSince(started) * 1000)
        Self.logger.notice("check status=\(result.logName, privacy: .public) ms=\(elapsed)")
        return result
    }

    private func publish(_ next: ServerStatus) {
        let changed = next != status
        status = next
        if changed { for continuation in continuations.values { continuation.yield(next) } }
    }

    private func evaluateWithinLimit() async -> ServerStatus {
        let sleep = self.sleep
        return await withTaskGroup(of: ServerStatus.self) { group in
            group.addTask { await self.evaluate() }
            group.addTask {
                try? await sleep(Self.checkTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .notReachable
            group.cancelAll()
            return first
        }
    }

    /// The checks in order: reachable, vision model installed, model chosen, chosen model usable.
    private func evaluate() async -> ServerStatus {
        let client = self.client()
        let version: String
        let models: [InstalledModel]
        do {
            version = try await client.version()
            models = try await client.models()
        } catch OllamaClientError.timedOut {
            return .timedOut
        } catch {
            return .notReachable
        }
        let usable = models.filter(\.readsImages)
        if usable.isEmpty { return .noVisionModel }
        guard let chosen = settings.model else { return .noModelChosen }
        if !usable.contains(where: { $0.name == chosen }) { return .modelMissing(chosen) }
        return .reachable(version: version)
    }
}
