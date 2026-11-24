import Darwin
import Foundation

/// Reads the current credential only for the matching live local daemon.
public struct LocalDaemonCredentialStore: Sendable {
    private struct Lock: Decodable {
        let pid: pid_t
        let listen: String
        let serverId: String
    }

    private let home: URL
    private let isProcessRunning: @Sendable (pid_t) -> Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo", isDirectory: true),
        isProcessRunning: (@Sendable (pid_t) -> Bool)? = nil
    ) {
        self.home = home
        self.isProcessRunning = isProcessRunning ?? { pid in kill(pid, 0) == 0 }
    }

    public func credential(serverId: String, url: URL) -> (url: URL, token: String)? {
        guard home.isFileURL, !serverId.isEmpty,
              let target = Self.loopbackWebSocketComponents(url),
              target.components.percentEncodedPath == "/ws", target.components.percentEncodedQuery == nil,
              let targetPort = target.components.port, (1...65535).contains(targetPort),
              let lockData = read("paseo.pid", limit: 16 * 1024),
              let lock = try? JSONDecoder().decode(Lock.self, from: lockData),
              lock.serverId == serverId,
              let listen = try? DaemonEndpoints.parseHostPort(lock.listen),
              listen.port == targetPort, let listener = Self.loopbackHost(listen.host),
              let destination = Self.credentialDestination(url, target: target, listener: listener),
              lock.pid > 0, isProcessRunning(lock.pid),
              let tokenData = read("local-credential", limit: 128, mode: 0o600),
              let text = String(data: tokenData, encoding: .utf8) else {
            return nil
        }

        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.wholeMatch(of: #/[A-Za-z0-9_-]{43}/#) != nil else { return nil }
        return (destination, token)
    }

    public nonisolated static func isLoopbackWebSocketURL(_ url: URL) -> Bool {
        loopbackWebSocketComponents(url) != nil
    }

    private static func loopbackWebSocketComponents(_ url: URL) -> (components: URLComponents, host: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              components.user == nil, components.password == nil, components.fragment == nil,
              let encodedHost = components.percentEncodedHost, let host = loopbackHost(encodedHost) else {
            return nil
        }
        return (components, host)
    }

    private static func credentialDestination(
        _ url: URL, target: (components: URLComponents, host: String), listener: String
    ) -> URL? {
        // A hostname alone does not identify which loopback address owns the listener.
        guard listener != "localhost" else { return nil }
        if target.host == listener { return url }
        // The desktop stores literal loopback routes as localhost. Dial the
        // recorded address directly so another address family cannot receive the token.
        // Keep the original hostname for TLS certificate validation.
        guard target.host == "localhost", target.components.scheme?.lowercased() == "ws" else { return nil }
        var components = target.components
        components.percentEncodedHost = listener == "::1" ? "[::1]" : listener
        return components.url
    }

    private static func loopbackHost(_ host: String) -> String? {
        // Keep distinct loopback binds separate even when they use the same port.
        let host = host.lowercased()
        switch host {
        case "localhost", "127.0.0.1", "::1": return host
        case "[::1]": return "::1"
        default: return nil
        }
    }

    private func read(_ name: String, limit: Int, mode: mode_t? = nil) -> Data? {
        let url = home.appendingPathComponent(name, isDirectory: false)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o022) == 0,
              info.st_size >= 0, info.st_size <= limit else {
            return nil
        }
        if let mode, (info.st_mode & 0o7777) != mode { return nil }
        var bytes = Data()
        do {
            while bytes.count <= limit,
                  let chunk = try file.read(upToCount: limit + 1 - bytes.count), !chunk.isEmpty {
                bytes.append(chunk)
            }
        } catch {
            return nil
        }
        return bytes.count <= limit ? bytes : nil
    }
}
