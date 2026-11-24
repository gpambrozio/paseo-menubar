import Darwin
import Foundation
import Testing
@testable import PaseoIconCore

struct LocalDaemonCredentialStoreTests {
    private struct Fixture {
        static let serverId = "fixture-daemon"
        static let pid: pid_t = 4321
        static let firstToken = String(repeating: "a", count: 43)
        static let secondToken = String(repeating: "b", count: 42) + "_"

        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "paseo-local-credential-\(UUID())", isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func writeLock(
            serverId: String = Self.serverId, listen: String = "127.0.0.1:6767", pid: pid_t = Self.pid
        ) throws {
            let fields: [String: Any] = [
                "serverId": serverId, "listen": listen, "pid": pid,
            ]
            let contents = try JSONSerialization.data(withJSONObject: fields)
            try contents.write(to: directory.appendingPathComponent("paseo.pid"))
        }

        func writeToken(_ content: String = Self.firstToken + "\n", mode: Int = 0o600) throws {
            let url = directory.appendingPathComponent("local-credential")
            try Data(content.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }

        var store: LocalDaemonCredentialStore {
            LocalDaemonCredentialStore(home: directory, isProcessRunning: { $0 == Self.pid })
        }
    }

    @Test("accepts the matching local daemon over literal IPv4 and IPv6", arguments: [
        ("ws://127.0.0.1:6767/ws", "127.0.0.1:6767"),
        ("wss://[::1]:6767/ws", "[::1]:6767"),
    ])
    func matchingLoopback(_ target: String, _ listen: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock(listen: listen)
        try fixture.writeToken()

        let url = try #require(URL(string: target))
        #expect(LocalDaemonCredentialStore.isLoopbackWebSocketURL(url))
        let credential = try #require(fixture.store.credential(serverId: Fixture.serverId, url: url))
        #expect(credential.url == url)
        #expect(credential.token == Fixture.firstToken)
    }

    @Test("dials the recorded literal address for desktop localhost routes", arguments: ["127.0.0.1", "[::1]"])
    func resolvesDesktopLoopbackAlias(_ host: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock(listen: "\(host):6767")
        try fixture.writeToken()

        let url = try #require(URL(string: "ws://localhost:6767/ws"))
        let credential = try #require(fixture.store.credential(serverId: Fixture.serverId, url: url))
        #expect(credential.url.absoluteString == "ws://\(host):6767/ws")
        #expect(credential.token == Fixture.firstToken)
    }

    @Test("keeps credentials scoped to the exact loopback listener", arguments: [
        ("ws://LOCALHOST:6767/ws", "localhost:6767"),
        ("wss://localhost:6767/ws", "localhost:6767"),
        ("wss://localhost:6767/ws", "127.0.0.1:6767"),
        ("ws://127.0.0.1:6767/ws", "localhost:6767"),
        ("ws://127.0.0.1:6767/ws", "[::1]:6767"),
        ("ws://[::1]:6767/ws", "127.0.0.1:6767"),
    ])
    func rejectsDifferentLoopbackBind(_ target: String, _ listen: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock(listen: listen)
        try fixture.writeToken()

        let url = try #require(URL(string: target))
        #expect(fixture.store.credential(serverId: Fixture.serverId, url: url) == nil)
    }

    @Test("rejects remote destinations, wildcard addresses, and URL user info", arguments: [
        "ws://example.test:6767/ws",
        "ws://localhost.example.test:6767/ws",
        "ws://127.0.0.10:6767/ws",
        "ws://localhost.:6767/ws",
        "ws://0.0.0.0:6767/ws",
        "ws://[::]:6767/ws",
        "ws://user:pass@localhost:6767/ws",
        "ws://localhost:6767/ws#fragment",
        "http://localhost:6767/ws",
    ])
    func unsafeDestination(_ target: String) throws {
        let url = try #require(URL(string: target))
        #expect(!LocalDaemonCredentialStore.isLoopbackWebSocketURL(url))
    }

    @Test("rejects a relay-shaped URL, a different port or daemon, and an unmatched or stale lock")
    func rejectsNonmatchingRoute() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock()
        try fixture.writeToken()
        let store = fixture.store
        let url = try #require(URL(string: "ws://127.0.0.1:6767/ws"))
        let wrongPort = try #require(URL(string: "ws://localhost:6768/ws"))
        let relay = try #require(URL(string: "ws://localhost:6767/ws?serverId=fixture-daemon&role=client&v=2"))
        let remote = try #require(URL(string: "ws://example.test:6767/ws"))
        #expect(store.credential(serverId: Fixture.serverId, url: wrongPort) == nil)
        #expect(store.credential(serverId: Fixture.serverId, url: relay) == nil)
        #expect(store.credential(serverId: Fixture.serverId, url: remote) == nil)
        #expect(store.credential(serverId: "other-daemon", url: url) == nil)

        try fixture.writeLock(listen: "0.0.0.0:6767")
        #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
        try fixture.writeLock(pid: 9876)
        #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
        try fixture.writeLock(pid: 0)
        let permissiveChecker = LocalDaemonCredentialStore(home: fixture.directory, isProcessRunning: { _ in true })
        #expect(permissiveChecker.credential(serverId: Fixture.serverId, url: url) == nil)
    }

    @Test("rejects readable token files, truncated or invalid tokens, and oversized lock files")
    func rejectsInvalidFiles() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock()
        let store = fixture.store
        let url = try #require(URL(string: "ws://127.0.0.1:6767/ws"))
        try fixture.writeToken(mode: 0o644)
        #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
        for invalid in [
            String(Fixture.firstToken.dropLast()),
            String(Fixture.firstToken.dropLast()) + "=",
            Fixture.firstToken + String(repeating: " ", count: 256),
        ] {
            try fixture.writeToken(invalid)
            #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
        }

        try fixture.writeToken()
        let lockURL = fixture.directory.appendingPathComponent("paseo.pid")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lockURL.path)
        #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)
        let lock = try Data(contentsOf: lockURL)
        try (lock + Data(repeating: 0x20, count: 16 * 1024)).write(to: lockURL)
        #expect(store.credential(serverId: Fixture.serverId, url: url) == nil)
    }

    @Test("rejects symlinks for both input files", arguments: ["paseo.pid", "local-credential"])
    func rejectsSymlink(_ name: String) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock()
        try fixture.writeToken()
        let original = fixture.directory.appendingPathComponent(name)
        let destination = fixture.directory.appendingPathComponent("symlink-target")
        try FileManager.default.moveItem(at: original, to: destination)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: destination)

        let url = try #require(URL(string: "ws://127.0.0.1:6767/ws"))
        #expect(fixture.store.credential(serverId: Fixture.serverId, url: url) == nil)
    }

    @Test("reads a replaced token on the next call")
    func readsRotation() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.writeLock()
        try fixture.writeToken()
        let store = fixture.store
        let url = try #require(URL(string: "ws://127.0.0.1:6767/ws"))
        #expect(store.credential(serverId: Fixture.serverId, url: url)?.token == Fixture.firstToken)

        try fixture.writeToken(Fixture.secondToken + "\n")
        #expect(store.credential(serverId: Fixture.serverId, url: url)?.token == Fixture.secondToken)
    }
}
