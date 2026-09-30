import Darwin
import Foundation
import Testing
@testable import MemorriCore

/// Answers requests from a closure instead of the network; the closure sees every request.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data, redirectTo: URL?))?
    nonisolated(unsafe) static var seen: [URL] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data, redirectTo: URL?)) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler; seen = []
    }
    static var seenURLs: [URL] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request.url!); let handler = Self.handler; Self.lock.unlock()
        guard let (response, data, redirect) = handler?(request) else { return }
        if let redirect {
            // A followed redirect would cancel this load; a refused one returns the 302 itself.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A local TCP listener that completes connections but never answers (for the timeout test).
final class SilentListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// A port that nothing listens on: bind, read the number, close.
    static func closedPort() throws -> Int {
        let listener = try SilentListener()
        let port = listener.port
        listener.close()
        return port
    }

    func close() { Darwin.close(descriptor) }
    deinit { close() }
}

@Suite(.serialized) struct OllamaURLSessionTransportTests {
    private func stubbedTransport(_ text: String = "http://localhost:11434") throws -> OllamaURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return OllamaURLSessionTransport(address: try #require(LoopbackAddress(text)), configuration: configuration)
    }

    private func ok(_ url: URL, _ body: String = "{}") -> (HTTPURLResponse, Data, redirectTo: URL?) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8), nil)
    }

    @Test func aRequestGoesOnlyToTheAddressItWasBuiltFrom() async throws {
        StubURLProtocol.reset { [self] request in ok(request.url!, #"{"version":"1"}"#) }
        let transport = try stubbedTransport("http://127.0.0.1:8080")
        let response = try await transport.send(OllamaHTTPRequest(method: .get, path: "/api/version", timeout: 5))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"version":"1"}"#)
        #expect(StubURLProtocol.seenURLs.map(\.absoluteString) == ["http://127.0.0.1:8080/api/version"])
    }

    @Test func aPostSendsItsBodyAndMethod() async throws {
        nonisolated(unsafe) var seenMethod: String?
        nonisolated(unsafe) var seenBody: Data?
        StubURLProtocol.reset { [self] request in
            seenMethod = request.httpMethod
            seenBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            }
            return ok(request.url!)
        }
        let transport = try stubbedTransport()
        _ = try await transport.send(OllamaHTTPRequest(method: .post, path: "/api/chat", body: Data("hello".utf8), timeout: 5))
        #expect(seenMethod == "POST")
        #expect(seenBody == Data("hello".utf8))
    }

    @Test func aRedirectIsRefusedAndNeverFollowed() async throws {
        StubURLProtocol.reset { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://example.com/steal"])!,
             Data(), redirectTo: URL(string: "http://example.com/steal"))
        }
        let transport = try stubbedTransport()
        await #expect(throws: OllamaTransportError.redirectRefused) {
            _ = try await transport.send(OllamaHTTPRequest(method: .get, path: "/api/tags", timeout: 5))
        }
        #expect(!StubURLProtocol.seenURLs.contains { $0.host == "example.com" })
    }

    @Test func noAnswerWithinTheTimeoutIsATimeout() async throws {
        let listener = try SilentListener()
        let transport = OllamaURLSessionTransport(address: try #require(LoopbackAddress("http://127.0.0.1:\(listener.port)")))
        await #expect(throws: OllamaTransportError.timedOut) {
            _ = try await transport.send(OllamaHTTPRequest(method: .get, path: "/api/version", timeout: 0.5))
        }
    }

    @Test func aClosedLocalPortIsUnreachable() async throws {
        let port = try SilentListener.closedPort()
        let transport = OllamaURLSessionTransport(address: try #require(LoopbackAddress("http://127.0.0.1:\(port)")))
        await #expect(throws: OllamaTransportError.unreachable) {
            _ = try await transport.send(OllamaHTTPRequest(method: .get, path: "/api/version", timeout: 5))
        }
    }

    @Test func aPathThatWouldLeaveTheServerIsNotSent() async throws {
        StubURLProtocol.reset { [self] request in ok(request.url!) }
        let transport = try stubbedTransport()
        await #expect(throws: OllamaTransportError.other("request is not for the loopback address")) {
            _ = try await transport.send(OllamaHTTPRequest(method: .get, path: "@evil.com/x", timeout: 5))
        }
        #expect(StubURLProtocol.seenURLs.isEmpty)
    }
}
