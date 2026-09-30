import Foundation
import Testing
@testable import MemorriCore

@Suite struct LoopbackAddressTests {
    @Test(arguments: [
        "http://localhost:11434", "http://127.0.0.1:8080", "http://[::1]:11434", "https://localhost",
        "http://localhost", "  http://localhost:11434  ", "HTTP://LOCALHOST:11434", "http://localhost:11434/",
    ])
    func acceptsAddressesOnThisMac(text: String) {
        #expect(LoopbackAddress(text) != nil)
    }

    @Test(arguments: [
        "http://example.com", "http://192.168.1.5:11434", "http://10.0.0.2", "http://8.8.8.8",
        "http://localhost.evil.com", "http://127.0.0.1.evil.com", "http://user@evil.com@localhost",
        "http://user:pass@localhost", "ftp://localhost", "localhost:11434", "http://localhost/api",
        "http://localhost?x=1", "http://localhost#frag", "http://0.0.0.0:11434", "http://[::2]:11434",
        "http://127.0.0.2:11434", "", "   ", "not a url",
    ])
    func rejectsEverythingElse(text: String) {
        #expect(LoopbackAddress(text) == nil)
    }

    @Test func standardAddressIsTheOllamaDefault() {
        #expect(LoopbackAddress.standard.text == "http://localhost:11434")
    }

    @Test func textKeepsWhatWasTypedWithoutTheSlashOrSpaces() throws {
        #expect(try #require(LoopbackAddress("  http://localhost:11434/ ")).text == "http://localhost:11434")
        #expect(try #require(LoopbackAddress("http://localhost")).text == "http://localhost")
        #expect(try #require(LoopbackAddress("http://[::1]:8080")).text == "http://[::1]:8080")
    }

    @Test func urlRoundTripsText() throws {
        for text in ["http://localhost:11434", "http://127.0.0.1:8080", "http://[::1]:11434", "https://localhost"] {
            let address = try #require(LoopbackAddress(text))
            #expect(address.url.absoluteString == address.text)
            #expect(LoopbackAddress(address.text) == address)
        }
    }
}
