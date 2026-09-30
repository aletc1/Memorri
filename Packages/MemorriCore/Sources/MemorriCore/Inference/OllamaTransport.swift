import Foundation

public struct OllamaHTTPRequest: Sendable, Equatable {
    public enum Method: Sendable, Equatable { case get, post }

    public let method: Method
    /// `/api/version`, `/api/tags`, `/api/show` or `/api/chat`.
    public let path: String
    public let body: Data?
    public let timeout: TimeInterval

    public init(method: Method, path: String, body: Data? = nil, timeout: TimeInterval) {
        self.method = method
        self.path = path
        self.body = body
        self.timeout = timeout
    }
}

public struct OllamaHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum OllamaTransportError: Error, Sendable, Equatable {
    /// Connection refused, or no route to the server.
    case unreachable
    case timedOut
    /// A redirect is never followed (ADR 0011).
    case redirectRefused
    case other(String)
}

/// How requests reach the server. The real one is the loopback-only transport (ADR 0011); tests use a fake.
public protocol OllamaTransport: Sendable {
    func send(_ request: OllamaHTTPRequest) async throws -> OllamaHTTPResponse
}
