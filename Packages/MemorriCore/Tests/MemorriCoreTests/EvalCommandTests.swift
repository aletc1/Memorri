import Foundation
import Testing
@testable import MemorriCore

@Suite struct EvalCommandTests {
    private func parse(_ words: String...) throws -> EvalCommand { try EvalCommand.parse(words) }

    @Test func generateSyntheticHasADefaultFolder() throws {
        #expect(try parse("generate-synthetic") == .generateSynthetic(out: "eval/golden/synthetic"))
        #expect(try parse("generate-synthetic", "--out", "/tmp/x") == .generateSynthetic(out: "/tmp/x"))
        #expect(try parse("generate-synthetic", "--out=/tmp/y") == .generateSynthetic(out: "/tmp/y"))
    }

    @Test func runDefaults() throws {
        guard case .run(let o) = try parse("run") else { Issue.record("not a run"); return }
        #expect(o.cases == "eval/golden")
        #expect(o.out == nil && o.model == nil && o.only == nil && o.replay == nil)
        #expect(o.size == 2048)
        #expect(o.think == .off)
        #expect(o.promptSet == "v1")
        #expect(o.address == "http://localhost:11434")
        #expect(o.allowBusy == false)
        #expect(o.minRecall == nil && o.minPrecision == nil)
    }

    @Test func runTakesEveryOption() throws {
        let command = try parse("run", "--cases", "c", "--out", "o.json", "--size", "1536", "--model", "m", "--think", "low", "--prompt-set", "v1",
                                "--address", "http://127.0.0.1:1234", "--only", "case-a", "--replay", "old.json", "--allow-busy",
                                "--min-recall", "0.8", "--min-precision", "0.7")
        guard case .run(let o) = command else { Issue.record("not a run"); return }
        #expect(o.cases == "c" && o.out == "o.json" && o.size == 1536 && o.model == "m" && o.think == .low)
        #expect(o.address == "http://127.0.0.1:1234" && o.only == "case-a" && o.replay == "old.json" && o.allowBusy)
        #expect(o.minRecall == 0.8 && o.minPrecision == 0.7)
    }

    @Test func compareNeedsTwoReports() throws {
        #expect(try parse("compare", "a.json", "b.json") == .compare(a: "a.json", b: "b.json"))
        #expect(throws: EvalUsageError.self) { try parse("compare", "a.json") }
        #expect(throws: EvalUsageError.self) { try parse("compare", "a.json", "b.json", "c.json") }
    }

    @Test func sweepSizeTakesASizeList() throws {
        #expect(try parse("sweep-size") == .sweepSize(cases: "eval/golden", sizes: [1024, 1536, 2048, 3072]))
        #expect(try parse("sweep-size", "--cases", "x", "--sizes", "1024,2048") == .sweepSize(cases: "x", sizes: [1024, 2048]))
        #expect(throws: EvalUsageError.self) { try parse("sweep-size", "--sizes", "1024,abc") }
        #expect(throws: EvalUsageError.self) { try parse("sweep-size", "--sizes", "10") }
    }

    @Test func noCommandOrHelpShowsTheUsage() throws {
        #expect(try EvalCommand.parse([]) == .help)
        #expect(try parse("--help") == .help)
        #expect(try parse("help") == .help)
        #expect(EvalCommand.usage.contains("generate-synthetic"))
    }

    @Test func usageErrorsHaveReadableTextAndExitCodeOne() {
        for words in [["frobnicate"], ["run", "--nope"], ["run", "--size"], ["run", "--size", "big"], ["run", "--size", "100"],
                      ["run", "--think", "max"], ["run", "--prompt-set", "v9"], ["run", "--min-recall", "2"], ["run", "stray"]] {
            do {
                _ = try EvalCommand.parse(words)
                Issue.record("\(words) should be a usage error")
            } catch let error as EvalUsageError {
                #expect(error.exitCode == 1)
                #expect(!error.description.isEmpty)
            } catch { Issue.record("wrong error \(error)") }
        }
    }

    @Test func anAddressThatIsNotLocalIsARefusal() {
        do {
            _ = try parse("run", "--address", "http://example.com:11434")
            Issue.record("should be rejected")
        } catch let error as EvalUsageError {
            #expect(error.exitCode == 2)
            #expect(error.description.contains("localhost"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func minimumsDecideExitCodeThree() throws {
        guard case .run(var o) = try parse("run", "--min-recall", "0.8", "--min-precision", "0.7") else { return }
        func numbers(precision: Double, recall: Double) -> OverallNumbers {
            OverallNumbers(cases: 1, precision: precision, recall: recall, fieldAccuracy: nil, classificationAccuracy: 1, meanSeconds: 1,
                           ocrExactRate: nil, ocrOverlapRate: nil, contextAccuracy: nil, wrongHighConfidenceTags: 0)
        }
        #expect(o.isBelowMinimum(numbers(precision: 0.9, recall: 0.9)) == false)
        #expect(o.isBelowMinimum(numbers(precision: 0.9, recall: 0.7)))
        #expect(o.isBelowMinimum(numbers(precision: 0.6, recall: 0.9)))
        o.minRecall = nil; o.minPrecision = nil
        #expect(o.isBelowMinimum(numbers(precision: 0, recall: 0)) == false)
        #expect(EvalExit.finished == 0 && EvalExit.error == 1 && EvalExit.refusal == 2 && EvalExit.belowMinimum == 3)
    }

    @Test func generateSequencesHasADefaultFolder() throws {
        #expect(try parse("generate-sequences") == .generateSequences(out: "eval/golden/synthetic-sequences"))
        #expect(try parse("generate-sequences", "--out", "/tmp/x") == .generateSequences(out: "/tmp/x"))
    }

    @Test func reconcileDefaultsToTheTrackedSetWithoutModels() throws {
        guard case .reconcile(let o) = try parse("reconcile") else { Issue.record("not a reconcile"); return }
        #expect(o.cases == "eval/golden/synthetic-sequences" && o.modelsOn == false && o.out == nil && o.only == nil)
        #expect(o.minMergeRecall == nil && o.maxWrongMerge == nil)
    }

    @Test func reconcileTakesEveryOption() throws {
        guard case .reconcile(let o) = try parse("reconcile", "--cases", "c", "--models", "on", "--embedding-model", "e", "--reranker-model", "r",
                                                 "--address", "http://127.0.0.1:11434", "--out", "o.json", "--only", "x",
                                                 "--min-merge-recall", "0.95", "--max-wrong-merge=0.02") else { Issue.record("not a reconcile"); return }
        #expect(o.cases == "c" && o.modelsOn && o.embeddingModel == "e" && o.rerankerModel == "r" && o.out == "o.json" && o.only == "x")
        #expect(o.minMergeRecall == 0.95 && o.maxWrongMerge == 0.02)
    }

    @Test func reconcileRejectsBadValuesAndAddressesOffThisMac() throws {
        #expect(throws: EvalUsageError.self) { try parse("reconcile", "--models", "maybe") }
        #expect(throws: EvalUsageError.self) { try parse("reconcile", "--min-merge-recall", "2") }
        #expect(throws: EvalUsageError.notLocal("http://example.com:11434")) { try parse("reconcile", "--address", "http://example.com:11434") }
        #expect(throws: EvalUsageError.unexpectedArgument("stray")) { try parse("reconcile", "stray") }
    }

    @Test func reconcileLimitsDecideTheExitCode() throws {
        var o = ReconcileOptions()
        let good = ReconcileOverall(captures: 1, items: 1, mergeRecall: 0.97, wrongMergeRate: 0.01, judgedShare: 0, msPerCapture: 1, translatedFlagged: nil,
                                    recreatedDismissed: 0, overwrittenTitles: 0)
        #expect(o.isOutsideLimits(good) == false)
        o.minMergeRecall = 0.98
        #expect(o.isOutsideLimits(good))
        o.minMergeRecall = 0.9; o.maxWrongMerge = 0.005
        #expect(o.isOutsideLimits(good))
    }

    @Test func runAcceptsTheReconcileFlag() throws {
        guard case .run(let o) = try parse("run", "--reconcile") else { Issue.record("not a run"); return }
        #expect(o.reconcile)
        guard case .run(let plain) = try parse("run") else { return }
        #expect(plain.reconcile == false)
    }
}
