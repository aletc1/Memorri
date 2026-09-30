import Foundation

/// The only file in the project that may use `URLSession` (ADR 0011, enforced by the no-network
/// scan). It is built from a `LoopbackAddress`, so it can only name this Mac; it re-checks the host
/// of every request before sending it; and it never follows a redirect.
public final class OllamaURLSessionTransport: OllamaTransport, @unchecked Sendable {
    private let address: LoopbackAddress
    private let session: URLSession

    public convenience init(address: LoopbackAddress) {
        self.init(address: address, configuration: .ephemeral)
    }

    /// Tests pass a configuration with a stub protocol.
    init(address: LoopbackAddress, configuration: URLSessionConfiguration) {
        self.address = address
        // The request's own timeout is the limit; the resource limit only has to be longer than
        // the longest setting (1800 s).
        configuration.timeoutIntervalForResource = 1900
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func send(_ request: OllamaHTTPRequest) async throws -> OllamaHTTPResponse {
        guard request.path.hasPrefix("/"),
              let url = URL(string: address.text + request.path),
              address.isSameServer(as: url) else {
            throw OllamaTransportError.other("request is not for the loopback address")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method == .get ? "GET" : "POST"
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw OllamaTransportError.other("not an HTTP response") }
            if (300..<400).contains(http.statusCode) { throw OllamaTransportError.redirectRefused }
            return OllamaHTTPResponse(status: http.statusCode, body: data)
        } catch let error as OllamaTransportError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw OllamaTransportError.other(error.localizedDescription)
        }
    }

    private static func map(_ error: URLError) -> OllamaTransportError {
        switch error.code {
        case .timedOut: .timedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet: .unreachable
        default: .other(error.localizedDescription)
        }
    }
}

/// Stops every redirect: the response that asked for it is returned and treated as a refusal.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
