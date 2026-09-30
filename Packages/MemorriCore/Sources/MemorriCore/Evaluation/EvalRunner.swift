import Foundation

/// Analyses one golden case the way the app would. `replaying` carries the stored model answers of an earlier run;
/// an analyser that gets them must not call the model.
public protocol CaseAnalysing: Sendable {
    func analyse(_ golden: GoldenCase, replaying steps: [EvalStepRecord]?) async throws -> CaseResult
}

/// Why a run did not start. Nothing is scored after a refusal.
public enum EvalRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case appBusy
    case serverUnavailable(String)
    case noCases
    case unknownCase(String)

    public var description: String {
        switch self {
        case .appBusy: "Pause analysis in Memorri first (or use --allow-busy)."
        case .serverUnavailable(let text): text
        case .noCases: "No cases to run."
        case .unknownCase(let name): "No case named \(name)."
        }
    }
}

/// Runs the golden cases through an analyser, scores them and builds the report (research R15, R17).
public struct EvalRunner: Sendable {
    let analyser: any CaseAnalysing
    let settings: EvalSettings
    let isAppBusy: @Sendable () -> Bool
    let serverStatus: @Sendable () async -> ServerStatus
    let now: @Sendable () -> Date

    public init(analyser: any CaseAnalysing, settings: EvalSettings, isAppBusy: @escaping @Sendable () -> Bool,
                serverStatus: @escaping @Sendable () async -> ServerStatus, now: @escaping @Sendable () -> Date = { Date() }) {
        self.analyser = analyser; self.settings = settings; self.isAppBusy = isAppBusy; self.serverStatus = serverStatus; self.now = now
    }

    /// `replay` re-scores the stored answers of an earlier report: no server, no busy check, and only the cases that
    /// report contains. `progress` is told about each case as it starts.
    public func run(cases: [GoldenCase], only: String? = nil, replay: EvalReport? = nil, allowBusy: Bool = false,
                    progress: (@Sendable (String) -> Void)? = nil) async throws -> EvalReport {
        var selected = cases
        if let only {
            selected = cases.filter { $0.name == only }
            if selected.isEmpty { throw EvalRefusal.unknownCase(only) }
        }
        var stored: [String: [EvalStepRecord]] = [:]
        if let replay {
            for c in replay.cases { stored[c.name] = c.steps }
            selected = selected.filter { stored[$0.name] != nil }
        }
        if selected.isEmpty { throw EvalRefusal.noCases }

        var busy = false
        if replay == nil {
            busy = isAppBusy()
            if busy && !allowBusy { throw EvalRefusal.appBusy }
            let status = await serverStatus()
            if !status.isUsable { throw EvalRefusal.serverUnavailable(status.message) }
        }

        var items: [(GoldenCase, CaseResult)] = []
        for (index, golden) in selected.enumerated() {
            progress?("[\(index + 1)/\(selected.count)] \(golden.name)")
            do {
                items.append((golden, try await analyser.analyse(golden, replaying: stored[golden.name])))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A case that cannot be analysed finds nothing; the run goes on and the report shows the miss.
                items.append((golden, CaseResult(kind: "failed", findings: [], tags: [], contextName: nil, lines: [], seconds: 0, steps: [])))
            }
        }
        return EvalReport.build(settings: settings, cases: items, ranWhileAppBusy: busy && allowBusy, createdAt: now())
    }
}
