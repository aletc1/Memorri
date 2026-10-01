import Foundation

public enum EvalExit {
    public static let finished: Int32 = 0
    public static let error: Int32 = 1
    public static let refusal: Int32 = 2
    public static let belowMinimum: Int32 = 3
}

/// A wrong command line. A non-local `--address` is a refusal (exit 2), everything else a plain error (exit 1).
public enum EvalUsageError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String, expected: String)
    case unexpectedArgument(String)
    case notLocal(String)

    public var exitCode: Int32 {
        if case .notLocal = self { return EvalExit.refusal }
        return EvalExit.error
    }

    public var description: String {
        switch self {
        case .unknownCommand(let word): "Unknown command \"\(word)\"."
        case .unknownOption(let word): "Unknown option \(word)."
        case .missingValue(let option): "\(option) needs a value."
        case .invalidValue(let option, let value, let expected): "\(option) \"\(value)\" is not valid (\(expected))."
        case .unexpectedArgument(let word): "Unexpected argument \"\(word)\"."
        case .notLocal(let address): "\"\(address)\" is not on this Mac. Only localhost, 127.0.0.1 and ::1 are allowed."
        }
    }
}

public struct RunOptions: Sendable, Equatable {
    public var cases = "eval/golden"
    public var out: String?
    public var size = StorageSettings.defaultModelLongEdge
    public var model: String?
    public var think = ThinkSetting.off
    public var promptSet = "v1"
    public var address = LoopbackAddress.standard.text
    public var only: String?
    public var replay: String?
    public var allowBusy = false
    public var minRecall: Double?
    public var minPrecision: Double?
    /// Reconcile the results of every case, then analyse and reconcile them again (SC-003, SC-007).
    public var reconcile = false

    /// True when a `--min-…` option was given and the run scored below it.
    public func isBelowMinimum(_ overall: OverallNumbers) -> Bool {
        if let minRecall, overall.recall < minRecall { return true }
        if let minPrecision, overall.precision < minPrecision { return true }
        return false
    }
}

public struct ReconcileOptions: Sendable, Equatable {
    public var cases = "eval/golden/synthetic-sequences"
    public var modelsOn = false
    public var embeddingModel: String?
    public var rerankerModel: String?
    public var address = LoopbackAddress.standard.text
    public var out: String?
    public var only: String?
    public var minMergeRecall: Double?
    public var maxWrongMerge: Double?

    /// True when a `--min-merge-recall` or `--max-wrong-merge` option was given and the run is outside it.
    public func isOutsideLimits(_ overall: ReconcileOverall) -> Bool {
        if let minMergeRecall, overall.mergeRecall < minMergeRecall { return true }
        if let maxWrongMerge, overall.wrongMergeRate > maxWrongMerge { return true }
        return false
    }
}

public enum EvalCommand: Sendable, Equatable {
    case generateSynthetic(out: String)
    case generateSequences(out: String)
    case reconcile(ReconcileOptions)
    case run(RunOptions)
    case compare(a: String, b: String)
    case sweepSize(cases: String, sizes: [Int])
    case help

    public static let promptSets = ["v1"]
    public static let defaultSizes = [1024, 1536, 2048, 3072]

    public static let usage = """
    memorri-eval: score Memorri's analysis against a golden set

    usage: memorri-eval <command> [options]

    commands:
      generate-synthetic [--out eval/golden/synthetic]
          draw the synthetic golden cases (the same files every time)
      generate-sequences [--out eval/golden/synthetic-sequences]
          write the synthetic sighting sequences for `reconcile` (the same files every time)
      reconcile [--cases eval/golden/synthetic-sequences] [--models off|on] [--embedding-model <name>] [--reranker-model <name>]
          [--address http://localhost:11434] [--out <report.json>] [--only <case>] [--min-merge-recall <x>] [--max-wrong-merge <x>]
          reconcile the sequences into scratch databases and score the matching (off needs no server)
      run [--cases eval/golden] [--out <report.json>] [--size 2048] [--model <name>] [--think off|low|medium|high]
          [--prompt-set v1] [--address http://localhost:11434] [--only <case>] [--replay <report.json>] [--allow-busy]
          [--min-recall <x>] [--min-precision <x>] [--reconcile]
          run the analysis over the cases and print the scores; --reconcile then counts items against distinct events
      compare <a.json> <b.json>
          print the difference between two saved reports
      sweep-size [--cases eval/golden] [--sizes 1024,1536,2048,3072]
          run the set at several picture sizes

    exit codes: 0 finished, 1 error, 2 refused (app busy, server unreachable, no cases, address not local), 3 below a minimum
    """

    public static func parse(_ arguments: [String]) throws -> EvalCommand {
        guard let first = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "help", "--help", "-h": return .help
        case "generate-synthetic":
            var words = try Words(rest, flags: [], options: ["--out"])
            return .generateSynthetic(out: try words.value("--out") ?? "eval/golden/synthetic")
        case "generate-sequences":
            var words = try Words(rest, flags: [], options: ["--out"])
            return .generateSequences(out: try words.value("--out") ?? "eval/golden/synthetic-sequences")
        case "reconcile": return .reconcile(try parseReconcile(rest))
        case "run": return .run(try parseRun(rest))
        case "compare":
            let words = try Words(rest, flags: [], options: [])
            guard words.positionals.count == 2 else {
                throw words.positionals.count < 2 ? EvalUsageError.missingValue("compare <a.json> <b.json>")
                                                   : EvalUsageError.unexpectedArgument(words.positionals[2])
            }
            return .compare(a: words.positionals[0], b: words.positionals[1])
        case "sweep-size":
            var words = try Words(rest, flags: [], options: ["--cases", "--sizes"])
            if let stray = words.positionals.first { throw EvalUsageError.unexpectedArgument(stray) }
            let sizes = try words.value("--sizes").map { text in
                try text.split(separator: ",").map { try size($0.trimmingCharacters(in: .whitespaces), option: "--sizes") }
            } ?? defaultSizes
            return .sweepSize(cases: try words.value("--cases") ?? "eval/golden", sizes: sizes)
        default: throw EvalUsageError.unknownCommand(first)
        }
    }

    private static func parseRun(_ rest: [String]) throws -> RunOptions {
        var words = try Words(rest, flags: ["--allow-busy", "--reconcile"],
                              options: ["--cases", "--out", "--size", "--model", "--think", "--prompt-set", "--address", "--only", "--replay",
                                        "--min-recall", "--min-precision"])
        if let stray = words.positionals.first { throw EvalUsageError.unexpectedArgument(stray) }
        var o = RunOptions()
        if let v = try words.value("--cases") { o.cases = v }
        o.out = try words.value("--out")
        if let v = try words.value("--size") { o.size = try size(v, option: "--size") }
        o.model = try words.value("--model")
        if let v = try words.value("--think") {
            guard let think = ThinkSetting(rawValue: v) else {
                throw EvalUsageError.invalidValue(option: "--think", value: v, expected: "off, low, medium or high")
            }
            o.think = think
        }
        if let v = try words.value("--prompt-set") {
            guard promptSets.contains(v) else {
                throw EvalUsageError.invalidValue(option: "--prompt-set", value: v, expected: "one of \(promptSets.joined(separator: ", "))")
            }
            o.promptSet = v
        }
        if let v = try words.value("--address") {
            guard let address = LoopbackAddress(v) else { throw EvalUsageError.notLocal(v) }
            o.address = address.text
        }
        o.only = try words.value("--only")
        o.replay = try words.value("--replay")
        o.allowBusy = words.flag("--allow-busy")
        o.reconcile = words.flag("--reconcile")
        o.minRecall = try words.value("--min-recall").map { try fraction($0, option: "--min-recall") }
        o.minPrecision = try words.value("--min-precision").map { try fraction($0, option: "--min-precision") }
        return o
    }

    private static func parseReconcile(_ rest: [String]) throws -> ReconcileOptions {
        var words = try Words(rest, flags: [], options: ["--cases", "--models", "--embedding-model", "--reranker-model", "--address", "--out", "--only",
                                                         "--min-merge-recall", "--max-wrong-merge"])
        if let stray = words.positionals.first { throw EvalUsageError.unexpectedArgument(stray) }
        var o = ReconcileOptions()
        if let v = try words.value("--cases") { o.cases = v }
        if let v = try words.value("--models") {
            guard ["on", "off"].contains(v) else { throw EvalUsageError.invalidValue(option: "--models", value: v, expected: "on or off") }
            o.modelsOn = v == "on"
        }
        o.embeddingModel = try words.value("--embedding-model")
        o.rerankerModel = try words.value("--reranker-model")
        if let v = try words.value("--address") {
            guard let address = LoopbackAddress(v) else { throw EvalUsageError.notLocal(v) }
            o.address = address.text
        }
        o.out = try words.value("--out")
        o.only = try words.value("--only")
        o.minMergeRecall = try words.value("--min-merge-recall").map { try fraction($0, option: "--min-merge-recall") }
        o.maxWrongMerge = try words.value("--max-wrong-merge").map { try fraction($0, option: "--max-wrong-merge") }
        return o
    }

    private static func size(_ text: String, option: String) throws -> Int {
        guard let value = Int(text), StorageSettings.modelLongEdgeRange.contains(value) else {
            let range = StorageSettings.modelLongEdgeRange
            throw EvalUsageError.invalidValue(option: option, value: text, expected: "a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }

    private static func fraction(_ text: String, option: String) throws -> Double {
        guard let value = Double(text), (0...1).contains(value) else {
            throw EvalUsageError.invalidValue(option: option, value: text, expected: "a number from 0 to 1")
        }
        return value
    }

    /// Splits `--name value`, `--name=value`, flags and positional words.
    private struct Words {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []

        init(_ arguments: [String], flags allowedFlags: Set<String>, options: Set<String>) throws {
            var index = 0
            while index < arguments.count {
                let word = arguments[index]
                index += 1
                guard word.hasPrefix("--") else { positionals.append(word); continue }
                if let equals = word.firstIndex(of: "=") {
                    let name = String(word[..<equals])
                    guard options.contains(name) else { throw EvalUsageError.unknownOption(name) }
                    values[name] = String(word[word.index(after: equals)...])
                } else if allowedFlags.contains(word) {
                    flags.insert(word)
                } else if options.contains(word) {
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw EvalUsageError.missingValue(word) }
                    values[word] = arguments[index]
                    index += 1
                } else {
                    throw EvalUsageError.unknownOption(word)
                }
            }
        }

        mutating func value(_ name: String) throws -> String? { values[name] }
        func flag(_ name: String) -> Bool { flags.contains(name) }
    }
}
