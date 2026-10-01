import Foundation

/// How much the model thinks before it answers.
public enum ThinkSetting: String, Sendable, CaseIterable {
    case off, low, medium, high
}

/// What the user did with a model picker: nothing yet (the default applies when installed), chose none, or chose a name.
public enum ModelChoice: Sendable, Equatable {
    case unset, none, named(String)
}

/// The Ollama section's settings, with the rules from the spec: the address can only be on this
/// Mac (FR-002) and the timeout is 10 to 1800 seconds (FR-009). A rejected value keeps the previous
/// one. Defaults come from the spike (ADR 0013).
public struct OllamaSettings: Sendable {
    public static let addressKey = "memorri.ollama.address"
    public static let modelKey = "memorri.ollama.model"
    public static let thinkKey = "memorri.ollama.think"
    public static let timeoutKey = "memorri.ollama.timeoutSeconds"
    public static let pausedKey = "memorri.analysis.paused"

    /// `qwen3-vl:8b-instruct`: on the 27 synthetic cases it scored 0.83 precision and 0.87 recall at 9 seconds a picture, against 0.89 and 0.89
    /// at 21 seconds for `qwen3.8:27b-mlx`, which stays a good choice for the most accurate answers (ADR 0019).
    public static let recommendedModel = "qwen3-vl:8b-instruct"
    public static let embeddingModelKey = "memorri.matching.embeddingModel"
    public static let rerankerModelKey = "memorri.matching.rerankerModel"
    /// The local models reconciliation uses for the meaning of a title and for the uncertain band (spec 005, research R3 and R4).
    public static let defaultEmbeddingModel = "jeffh/intfloat-multilingual-e5-large-instruct:f32"
    public static let defaultRerankerModel = "fanyx/Qwen3-Reranker-0.6B-Q8_0:latest"
    public static let defaultTimeoutSeconds = 300
    public static let timeoutRange = 10...1800
    public static let defaultThink = ThinkSetting.off

    private let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
    }

    public var address: LoopbackAddress {
        store.string(forKey: Self.addressKey).flatMap(LoopbackAddress.init) ?? .standard
    }

    /// Returns false, leaving the stored address unchanged, for anything that is not on this Mac.
    @discardableResult
    public func setAddress(_ text: String) -> Bool {
        guard let address = LoopbackAddress(text) else { return false }
        store.setString(address.text, forKey: Self.addressKey)
        return true
    }

    public var model: String? {
        guard let name = store.string(forKey: Self.modelKey), !name.isEmpty else { return nil }
        return name
    }

    public func setModel(_ name: String?) {
        store.setString(name ?? "", forKey: Self.modelKey)
    }

    public var think: ThinkSetting {
        store.string(forKey: Self.thinkKey).flatMap(ThinkSetting.init(rawValue:)) ?? Self.defaultThink
    }

    public func setThink(_ value: ThinkSetting) {
        store.setString(value.rawValue, forKey: Self.thinkKey)
    }

    public var timeoutSeconds: Int {
        guard let value = store.int(forKey: Self.timeoutKey), Self.timeoutRange.contains(value) else {
            return Self.defaultTimeoutSeconds
        }
        return value
    }

    /// Returns false, leaving the stored value unchanged, when outside 10 to 1800.
    @discardableResult
    public func setTimeoutSeconds(_ value: Int) -> Bool {
        guard Self.timeoutRange.contains(value) else { return false }
        store.setInt(value, forKey: Self.timeoutKey)
        return true
    }

    public var analysisPaused: Bool {
        store.bool(forKey: Self.pausedKey, default: false)
    }

    public func setAnalysisPaused(_ value: Bool) {
        store.setBool(value, forKey: Self.pausedKey)
    }

    // MARK: Matching models

    public var embeddingChoice: ModelChoice { choice(forKey: Self.embeddingModelKey) }
    public var rerankerChoice: ModelChoice { choice(forKey: Self.rerankerModelKey) }

    /// `nil` means "None": text and time only.
    public func setEmbeddingModel(_ name: String?) { store.setString(name ?? "", forKey: Self.embeddingModelKey) }
    public func setRerankerModel(_ name: String?) { store.setString(name ?? "", forKey: Self.rerankerModelKey) }

    /// The model to call: the user's choice when installed, the default when nothing was chosen and it is installed, else none.
    public func embeddingModel(installed: Set<String>) -> String? {
        resolve(embeddingChoice, default: Self.defaultEmbeddingModel, installed: installed)
    }

    public func rerankerModel(installed: Set<String>) -> String? {
        resolve(rerankerChoice, default: Self.defaultRerankerModel, installed: installed)
    }

    private func choice(forKey key: String) -> ModelChoice {
        guard let text = store.string(forKey: key) else { return .unset }
        return text.isEmpty ? .none : .named(text)
    }

    private func resolve(_ choice: ModelChoice, default name: String, installed: Set<String>) -> String? {
        switch choice {
        case .unset: installed.contains(name) ? name : nil
        case .none: nil
        case .named(let chosen): installed.contains(chosen) ? chosen : nil
        }
    }
}
