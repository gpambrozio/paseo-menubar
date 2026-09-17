import Foundation

public struct HostPort: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let isIPv6: Bool
}

public enum DaemonEndpointError: Error, Equatable {
    case hostRequired
    case invalidHostPort(String)
    case invalidPort(String)
    case invalidURL(String)
}

/// URL builders copied from `@getpaseo/protocol` 0.4.0 `daemon-endpoints`.
/// A direct daemon listens at `/ws`; the relay takes the same path plus the
/// session id, the caller's role, and the relay protocol version.
public enum DaemonEndpoints {
    /// `CURRENT_RELAY_PROTOCOL_VERSION` upstream. Version 2 is the per-connection
    /// data-socket design; the relay rejects anything else with a 400.
    public static let relayProtocolVersion = "2"
    public static let defaultHostedRelayPort = 443

    public static func parseHostPort(_ input: String) throws -> HostPort {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DaemonEndpointError.hostRequired }
        if trimmed.hasPrefix("[") {
            guard let match = trimmed.wholeMatch(of: #/^\[([^\]]+)\]:(\d{1,5})$/#) else {
                throw DaemonEndpointError.invalidHostPort("expected [::1]:6767")
            }
            let host = match.1.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { throw DaemonEndpointError.hostRequired }
            return HostPort(host: host, port: try parsePort(String(match.2)), isIPv6: true)
        }
        guard let match = trimmed.wholeMatch(of: #/^(.+):(\d{1,5})$/#) else {
            throw DaemonEndpointError.invalidHostPort("expected localhost:6767")
        }
        let host = match.1.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw DaemonEndpointError.hostRequired }
        return HostPort(host: host, port: try parsePort(String(match.2)), isIPv6: false)
    }

    public static func daemonWebSocketURL(endpoint: String, useTls: Bool) throws -> URL {
        let parsed = try parseHostPort(endpoint)
        return try baseURL(parsed, useTls: useTls)
    }

    public static func relayWebSocketURL(endpoint: String, useTls: Bool, serverId: String) throws -> URL {
        let parsed = try parseHostPort(endpoint)
        let base = try baseURL(parsed, useTls: useTls)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DaemonEndpointError.invalidURL(base.absoluteString)
        }
        components.queryItems = [
            URLQueryItem(name: "serverId", value: serverId),
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "v", value: relayProtocolVersion),
        ]
        guard let url = components.url else { throw DaemonEndpointError.invalidURL(base.absoluteString) }
        return url
    }

    /// The hosted relay terminates TLS on 443 and an offer may omit `useTls`;
    /// this is the default the CLI applies in that case.
    public static func shouldUseTlsForDefaultHostedRelay(_ endpoint: String) -> Bool {
        guard let parsed = try? parseHostPort(endpoint) else { return false }
        return parsed.port == defaultHostedRelayPort
    }

    private static func baseURL(_ hostPort: HostPort, useTls: Bool) throws -> URL {
        let scheme = useTls ? "wss" : "ws"
        let hostPart = hostPort.isIPv6 ? "[\(hostPort.host)]" : hostPort.host
        let text = "\(scheme)://\(hostPart):\(hostPort.port)/ws"
        guard let url = URL(string: text) else { throw DaemonEndpointError.invalidURL(text) }
        return url
    }

    private static func parsePort(_ text: String) throws -> Int {
        guard let port = Int(text), (1...65535).contains(port) else {
            throw DaemonEndpointError.invalidPort(text)
        }
        return port
    }
}
