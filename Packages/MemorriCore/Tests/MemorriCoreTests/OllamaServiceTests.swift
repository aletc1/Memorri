import Foundation
import Testing
@testable import MemorriCore

@Suite struct OllamaServiceTests {
    private struct Rig {
        let service: OllamaService
        let transport: FakeOllamaTransport
        let settings: OllamaSettings
        let addresses: AddressLog
    }

    /// Records the address each transport was built for.
    final class AddressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
    }

    private func makeRig(model: String? = "qwen3.8:27b-mlx", shortTimeout: Bool = false) -> Rig {
        let transport = FakeOllamaTransport()
        let settings = OllamaSettings(store: FakeSettingsStore())
        settings.setModel(model)
        let addresses = AddressLog()
        let realSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(for: .seconds(seconds)) }
        let shortSleep: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(80)) }
        let service = OllamaService(
            settings: settings,
            makeTransport: { address in addresses.add(address.text); return transport },
            time: FakeTimeSource(0),
            sleep: shortTimeout ? shortSleep : realSleep)
        return Rig(service: service, transport: transport, settings: settings, addresses: addresses)
    }

    private func script(_ transport: FakeOllamaTransport, models: String? = nil) {
        transport.set("/api/version", .json(#"{"version":"0.34.4"}"#))
        transport.set("/api/tags", .json(models ?? """
            {"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision","tools","thinking"]},
                       {"name":"coder:30b","capabilities":["completion","tools"]}]}
            """))
    }

    @Test func aRunningServerWithTheChosenModelIsReachable() async {
        let rig = makeRig()
        script(rig.transport)
        #expect(await rig.service.check() == .reachable(version: "0.34.4"))
        #expect(await rig.service.status == .reachable(version: "0.34.4"))
    }

    @Test func aRefusedConnectionIsNotReachable() async {
        let rig = makeRig()
        rig.transport.set("/api/version", .fail(.unreachable))
        #expect(await rig.service.check() == .notReachable)
    }

    @Test func noAnswerWithinTheLimitIsTimedOut() async {
        let rig = makeRig(shortTimeout: true)
        script(rig.transport)
        rig.transport.delay = .seconds(60)
        #expect(OllamaService.checkTimeout == 5)
        #expect(await rig.service.check() == .timedOut)
    }

    @Test func aTransportTimeoutIsAlsoTimedOut() async {
        let rig = makeRig()
        rig.transport.set("/api/version", .fail(.timedOut))
        #expect(await rig.service.check() == .timedOut)
    }

    @Test func aServerThatFailsIsNotReachable() async {
        let rig = makeRig()
        rig.transport.set("/api/version", .status(500))
        #expect(await rig.service.check() == .notReachable)
    }

    @Test func noVisionModelComesBeforeTheChosenModelChecks() async {
        let rig = makeRig(model: "whatever")
        script(rig.transport, models: #"{"models":[{"name":"coder:30b","capabilities":["completion"]}]}"#)
        #expect(await rig.service.check() == .noVisionModel)
    }

    @Test func noModelChosenIsReportedWhenThereAreVisionModels() async {
        let rig = makeRig(model: nil)
        script(rig.transport)
        #expect(await rig.service.check() == .noModelChosen)
    }

    @Test func aChosenModelThatIsNotInstalledIsMissing() async {
        let rig = makeRig(model: "gone:1b")
        script(rig.transport)
        #expect(await rig.service.check() == .modelMissing("gone:1b"))
    }

    @Test func aChosenModelThatCannotReadImagesCountsAsMissing() async {
        let rig = makeRig(model: "coder:30b")
        script(rig.transport)
        #expect(await rig.service.check() == .modelMissing("coder:30b"))
    }

    @Test func theChecksAreEvaluatedInOrder() async {
        // Unreachable wins over everything; with no vision model and no choice, the vision check wins.
        let rig = makeRig(model: nil)
        script(rig.transport, models: #"{"models":[]}"#)
        #expect(await rig.service.check() == .noVisionModel)
        rig.transport.set("/api/version", .fail(.unreachable))
        #expect(await rig.service.check() == .notReachable)
    }

    @Test func twoChecksAtOnceShareOneSetOfRequests() async {
        let rig = makeRig()
        script(rig.transport)
        rig.transport.delay = .milliseconds(200)
        async let first = rig.service.check()
        async let second = rig.service.check()
        let results = await [first, second]
        #expect(results == [.reachable(version: "0.34.4"), .reachable(version: "0.34.4")])
        #expect(rig.transport.requests(to: "/api/version").count == 1)
        #expect(rig.transport.requests(to: "/api/tags").count == 1)
    }

    @Test func aLaterCheckAfterTheFirstFinishedAsksAgain() async {
        let rig = makeRig()
        script(rig.transport)
        _ = await rig.service.check()
        _ = await rig.service.check()
        #expect(rig.transport.requests(to: "/api/version").count == 2)
    }

    @Test func statusUpdatesStartWithTheCurrentStatusAndThenEachChangeOnce() async {
        let rig = makeRig()
        script(rig.transport)
        var iterator = await rig.service.statusUpdates().makeAsyncIterator()
        #expect(await iterator.next() == .unchecked)
        _ = await rig.service.check()
        #expect(await iterator.next() == .reachable(version: "0.34.4"))
        _ = await rig.service.check()                                     // same result: nothing emitted
        rig.transport.set("/api/version", .fail(.unreachable))
        _ = await rig.service.check()
        #expect(await iterator.next() == .notReachable)
    }

    @Test func aCheckAfterTheAddressChangesGoesToTheNewAddress() async {
        let rig = makeRig()
        script(rig.transport)
        _ = await rig.service.check()
        #expect(rig.settings.setAddress("http://127.0.0.1:9000"))
        _ = await rig.service.check()
        #expect(rig.addresses.values == ["http://localhost:11434", "http://127.0.0.1:9000"])
    }

    // MARK: model list and default choice (user story 2)

    private let sixModels = """
    {"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision","tools","thinking"]},
               {"name":"qwen3.6:35b-mlx","capabilities":["completion","vision","thinking","tools"]},
               {"name":"qwen3-coder:30b","capabilities":["completion","tools"]},
               {"name":"rerank-a","capabilities":["tools","thinking","completion"]},
               {"name":"rerank-b","capabilities":["tools","thinking","completion"]},
               {"name":"e5","capabilities":["embedding"]}]}
    """

    @Test func theListHasOnlyVisionModelsAndCountsTheHiddenOnes() async throws {
        let rig = makeRig()
        script(rig.transport, models: sixModels)
        let list = try await rig.service.modelList()
        #expect(list.usable.map(\.name) == ["qwen3.8:27b-mlx", "qwen3.6:35b-mlx"])
        #expect(list.usable.allSatisfy { $0.readsImages })
        #expect(list.hiddenCount == 4)
        #expect(list.usable.first?.thinks == true)
    }

    @Test func aFailingServerMakesTheListThrow() async {
        let rig = makeRig()
        rig.transport.set("/api/tags", .fail(.unreachable))
        do {
            _ = try await rig.service.modelList()
            Issue.record("expected the list to throw")
        } catch {
            #expect(error as? OllamaClientError == .unreachable)
        }
    }

    @Test func modelsWithoutCapabilitiesAreResolvedThroughShow() async throws {
        let rig = makeRig()
        rig.transport.set("/api/tags", .json(#"{"models":[{"name":"old:1"},{"name":"text:1"}]}"#))
        rig.transport.set("/api/show", .json(#"{"capabilities":["completion","vision"]}"#))
        let list = try await rig.service.modelList()
        #expect(list.usable.count == 2)                      // the scripted /api/show answers "vision" for both
        #expect(rig.transport.requests(to: "/api/show").count == 2)
    }

    @Test func theRecommendedModelIsChosenWhenNothingIsChosenAndItIsInstalled() async {
        let rig = makeRig(model: nil)
        script(rig.transport, models: sixModels)
        await rig.service.applyDefaultModelIfNeeded()
        #expect(rig.settings.model == "qwen3.8:27b-mlx")
    }

    @Test func nothingIsChosenWhenTheRecommendedModelIsNotInstalled() async {
        let rig = makeRig(model: nil)
        script(rig.transport, models: #"{"models":[{"name":"qwen3.6:35b-mlx","capabilities":["completion","vision"]}]}"#)
        await rig.service.applyDefaultModelIfNeeded()
        #expect(rig.settings.model == nil)
    }

    @Test func anExistingChoiceIsNeverReplaced() async {
        let rig = makeRig(model: "qwen3.6:35b-mlx")
        script(rig.transport, models: sixModels)
        await rig.service.applyDefaultModelIfNeeded()
        #expect(rig.settings.model == "qwen3.6:35b-mlx")
        #expect(rig.transport.requests.isEmpty)              // nothing to do, so the server is not even asked
    }

    @Test func aFailingServerLeavesTheChoiceEmpty() async {
        let rig = makeRig(model: nil)
        rig.transport.set("/api/tags", .fail(.unreachable))
        await rig.service.applyDefaultModelIfNeeded()
        #expect(rig.settings.model == nil)
    }

    @Test func aChosenModelThatDisappearsKeepsItsNameAndTheStatusSaysMissing() async {
        let rig = makeRig(model: "qwen3.8:27b-mlx")
        script(rig.transport)
        #expect(await rig.service.check() == .reachable(version: "0.34.4"))
        script(rig.transport, models: #"{"models":[{"name":"qwen3.6:35b-mlx","capabilities":["completion","vision"]}]}"#)
        #expect(await rig.service.check() == .modelMissing("qwen3.8:27b-mlx"))
        #expect(rig.settings.model == "qwen3.8:27b-mlx")     // not silently replaced (FR-007)
    }
}
