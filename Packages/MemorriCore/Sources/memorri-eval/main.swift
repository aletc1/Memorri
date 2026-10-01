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

/// The real analysis: the same pipeline the app runs, with the model choices from the command line.
struct CLIAnalyser: CaseAnalysing {
    let service: OllamaService
    let settings: OllamaSettings
    let size: Int
    let contexts: [ContextRecord]

    func analyse(_ golden: GoldenCase, replaying steps: [EvalStepRecord]?) async throws -> CaseResult {
        let stepSettings: ModelStepSettings
        if steps != nil {
            // Replaying never calls the model, so the server is not asked about it.
            stepSettings = ModelStepSettings(model: settings.model ?? "", think: settings.think, timeout: 60, modelThinks: false)
        } else {
            switch await ModelStep.settings(service: service, settings: settings) {
            case .success(let value): stepSettings = value
            case .failure: throw EvalRefusal.serverUnavailable(ServerStatus.noModelChosen.message)
            }
        }
        let analyser = PipelineCaseAnalyser(recogniser: TiledTextRecogniser(base: VisionTextRecogniser()), model: ServiceModelChatting(service: service),
                                            settings: stepSettings, size: size, contexts: contexts)
        return try await analyser.analyse(golden, replaying: steps)
    }
}

func defaultReportPath() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "eval/out/\(formatter.string(from: Date())).json"
}

/// The prompt and schema versions in use, saved with every report.
func promptVersions() -> [String: String] {
    var versions = ["classify": ExtractionPrompts.classifyVersion]
    for kind in ScreenKind.allCases { versions["extract-\(kind.rawValue)"] = ExtractionPrompts.version(for: kind) }
    return versions
}

func run(_ options: RunOptions) async -> Int32 {
    let store = MemorySettingsStore()
    let settings = OllamaSettings(store: store)
    _ = settings.setAddress(options.address)
    settings.setModel(options.model ?? OllamaSettings.recommendedModel)
    settings.setThink(options.think)
    let service = OllamaService.live(settings: settings)
    let evalSettings = EvalSettings(model: settings.model ?? OllamaSettings.recommendedModel, size: options.size, think: options.think.rawValue,
                                    promptVersions: promptVersions(), thresholds: .standard)
    do {
        let (cases, warnings) = try GoldenCase.loadAll(in: URL(fileURLWithPath: options.cases))
        for warning in warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        let analyser = CLIAnalyser(service: service, settings: settings, size: options.size, contexts: PipelineCaseAnalyser.contexts(in: cases))
        let runner = EvalRunner(analyser: analyser, settings: evalSettings,
                                isAppBusy: { (try? AppPaths.standard()).map(BusyCheck.isBusy(paths:)) ?? false },
                                serverStatus: { await service.check() })
        let replay = try options.replay.map(readReport)
        let report = try await runner.run(cases: cases, only: options.only, replay: replay, allowBusy: options.allowBusy,
                                          progress: { print($0) })
        print(report.text)
        let out = URL(fileURLWithPath: options.out ?? defaultReportPath())
        try report.write(to: out)
        print("saved \(out.path)")
        if report.cases.allSatisfy({ $0.foundKind == "failed" }) {
            fail("No case could be analysed (see the saved report for the model's answers).", code: EvalExit.error)
        }
        return options.isBelowMinimum(report.overall) ? EvalExit.belowMinimum : EvalExit.finished
    } catch let refusal as EvalRefusal {
        fail(refusal.description, code: EvalExit.refusal)
    } catch {
        fail("\(error)", code: EvalExit.error)
    }
}

func sweep(cases path: String, sizes: [Int]) async -> Int32 {
    let settings = OllamaSettings(store: MemorySettingsStore())
    settings.setModel(OllamaSettings.recommendedModel)
    let service = OllamaService.live(settings: settings)
    do {
        let (cases, warnings) = try GoldenCase.loadAll(in: URL(fileURLWithPath: path))
        for warning in warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        let contexts = PipelineCaseAnalyser.contexts(in: cases)
        let sweep = SizeSweep(runner: { size in
            let evalSettings = EvalSettings(model: settings.model ?? OllamaSettings.recommendedModel, size: size, think: settings.think.rawValue,
                                            promptVersions: promptVersions(), thresholds: .standard)
            return EvalRunner(analyser: CLIAnalyser(service: service, settings: settings, size: size, contexts: contexts), settings: evalSettings,
                              isAppBusy: { (try? AppPaths.standard()).map(BusyCheck.isBusy(paths:)) ?? false },
                              serverStatus: { await service.check() })
        })
        let result = try await sweep.run(cases: cases, sizes: sizes, progress: { print($0) })
        print(result.text)
        return EvalExit.finished
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
    case .sweepSize(let cases, let sizes):
        exit(await sweep(cases: cases, sizes: sizes))
    }
} catch let error as EvalUsageError {
    fail("\(error.description)\n\n\(EvalCommand.usage)", code: error.exitCode)
} catch {
    fail("\(error)", code: EvalExit.error)
}
