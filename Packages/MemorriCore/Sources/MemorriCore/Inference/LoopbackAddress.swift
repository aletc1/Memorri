import Foundation

/// The only way to name the model server (ADR 0011). It cannot hold an address that is not on this
/// Mac, so captured content cannot be sent anywhere else by mistake (FR-002).
public struct LoopbackAddress: Sendable, Equatable {
    public static let standard = LoopbackAddress(scheme: "http", host: "localhost", port: 11434)!

    public let url: URL
    public let host: String

    public var text: String { url.absoluteString }

    /// `nil` unless the text is an `http` or `https` URL whose host is exactly `localhost`,
    /// `127.0.0.1` or `::1`, with no user info, no path beyond `/`, no query and no fragment.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(),
              let rawHost = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil else { return nil }
        // Foundation may return an IPv6 host with its brackets.
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        self.init(scheme: scheme, host: host, port: parts.port)
    }

    private init?(scheme: String, host: String, port: Int?) {
        guard ["http", "https"].contains(scheme), ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let text = "\(scheme)://\(shownHost)" + (port.map { ":\($0)" } ?? "")
        guard let url = URL(string: text) else { return nil }
        self.url = url
        self.host = host
    }

    /// True when `url` points at this same server (same scheme, host and port), whatever its path.
    /// The transport checks every request with it.
    public func isSameServer(as other: URL) -> Bool {
        guard let parts = URLComponents(url: other, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil,
              let scheme = parts.scheme?.lowercased(), scheme == url.scheme?.lowercased(),
              let rawHost = parts.host?.lowercased() else { return false }
        let otherHost = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        return otherHost == host && parts.port == url.port
    }
}
