import Foundation
import MemorriCore

func fail(_ text: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

func readReport(_ path: String) throws -> EvalReport {
    do { return try EvalReport.decode(Data(contentsOf: URL(fileURLWithPath: path))) }
    catch { fail("Cannot read the report \(path): \(error.localizedDescription)", code: EvalExit.error) }
}

/// Until the analysis pipeline exists (user story 3) a case cannot be analysed.
struct UnwiredAnalyser: CaseAnalysing {
    func analyse(_ golden: GoldenCase, replaying steps: [EvalStepRecord]?) async throws -> CaseResult {
        throw PipelineError.permanent("the analysis pipeline is not connected yet")
    }
}

func defaultReportPath() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "eval/out/\(formatter.string(from: Date())).json"
}

func run(_ options: RunOptions) async -> Int32 {
    let store = MemorySettingsStore()
    let settings = OllamaSettings(store: store)
    _ = settings.setAddress(options.address)
    settings.setModel(options.model ?? OllamaSettings.recommendedModel)
    settings.setThink(options.think)
    let service = OllamaService.live(settings: settings)
    let evalSettings = EvalSettings(model: settings.model ?? OllamaSettings.recommendedModel, size: options.size, think: options.think.rawValue,
                                    promptVersions: [:], thresholds: .standard)
    let runner = EvalRunner(analyser: UnwiredAnalyser(), settings: evalSettings,
                            isAppBusy: { (try? AppPaths.standard()).map(BusyCheck.isBusy(paths:)) ?? false },
                            serverStatus: { await service.check() })
    do {
        let (cases, warnings) = try GoldenCase.loadAll(in: URL(fileURLWithPath: options.cases))
        for warning in warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        let replay = try options.replay.map(readReport)
        let report = try await runner.run(cases: cases, only: options.only, replay: replay, allowBusy: options.allowBusy,
                                          progress: { print($0) })
        print(report.text)
        let out = URL(fileURLWithPath: options.out ?? defaultReportPath())
        try report.write(to: out)
        print("saved \(out.path)")
        if report.cases.allSatisfy({ $0.foundKind == "failed" }) {
            fail("No case could be analysed: the analysis pipeline is not connected yet.", code: EvalExit.error)
        }
        return options.isBelowMinimum(report.overall) ? EvalExit.belowMinimum : EvalExit.finished
    } catch let refusal as EvalRefusal {
        fail(refusal.description, code: EvalExit.refusal)
    } catch {
        fail("\(error)", code: EvalExit.error)
    }
}

do {
    switch try EvalCommand.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(EvalCommand.usage)
    case .generateSynthetic(let out):
        let folders = try SyntheticCases.generate(into: URL(fileURLWithPath: out))
        print("wrote \(folders.count) cases to \(out)")
    case .compare(let a, let b):
        print(EvalReport.compare(try readReport(a), try readReport(b)).text)
    case .run(let options):
        exit(await run(options))
    case .sweepSize:
        fail("sweep-size is not implemented yet.", code: EvalExit.error)
    }
} catch let error as EvalUsageError {
    fail("\(error.description)\n\n\(EvalCommand.usage)", code: error.exitCode)
} catch {
    fail("\(error)", code: EvalExit.error)
}
