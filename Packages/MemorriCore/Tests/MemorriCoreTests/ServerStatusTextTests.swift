import Testing
@testable import MemorriCore

@Suite struct ServerStatusTextTests {
    @Test func textsMatchTheUIContract() {
        #expect(ServerStatus.unchecked.message == "Not checked yet.")
        #expect(ServerStatus.reachable(version: "0.34.4").message == "Reachable, Ollama 0.34.4")
        #expect(ServerStatus.notReachable.message == "Not reachable. Start Ollama and try again.")
        #expect(ServerStatus.timedOut.message == "No answer within 5 seconds.")
        #expect(ServerStatus.noVisionModel.message == "Ollama is running but no installed model can read images. Install a vision model.")
        #expect(ServerStatus.noModelChosen.message == "Choose a model.")
        #expect(ServerStatus.modelMissing("gone:1b").message == "The model gone:1b is not installed.")
    }

    @Test func onlyAReachableServerIsUsable() {
        #expect(ServerStatus.reachable(version: "1").isUsable)
        for status in [ServerStatus.unchecked, .notReachable, .timedOut, .noVisionModel, .noModelChosen, .modelMissing("x")] {
            #expect(!status.isUsable)
        }
    }
}
