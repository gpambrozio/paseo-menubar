import Foundation
import Testing
@testable import PaseoIconCore

/// Against a real `@getpaseo/server` 0.17.3 daemon booted by
/// `scripts/swift-test-daemon.mjs`. Slow by design; the daemon takes a few
/// seconds to start.
@MainActor
struct RealDaemonTests {
    @Test("local desktop credential connects despite a missing or stale saved password", arguments: [nil, "stale-saved-password"] as [String?])
    func localCredentialConnection(savedPassword: String?) async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs",
            arguments: ["--password", "fixture-daemon-password", "--local-credential"])
        defer { daemon.stop() }
        let serverId = try daemon.string("serverId")
        let endpoint = "localhost:\(try daemon.int("port"))"
        let credentialStore = LocalDaemonCredentialStore(home: URL(fileURLWithPath: try daemon.string("paseoHome")))
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: serverId, label: nil, endpoint: endpoint, useTls: false, password: savedPassword),
            sink: sink, clock: ContinuousClock(), localCredentialStore: credentialStore)
        defer { connection.close() }
        try #require(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        #expect(sink.events.contains(.seedWorkspaces(serverId, ids: [], truncated: false)))
        #expect(sink.events.contains(.seedAgents(serverId, ids: [], truncated: false)))
    }

    @Test("connects to a real daemon, seeds, and records its serverId and hostname")
    func connectsAndSeeds() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let serverId = try daemon.string("serverId")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: nil),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        #expect(sink.events.contains(.setServerId("real", serverId)))
        #expect(sink.events.contains(.seedWorkspaces("real", ids: [], truncated: false)))
        #expect(sink.events.contains(.seedAgents("real", ids: [], truncated: false)))
        #expect(sink.events.contains { if case .setHostname("real", let name) = $0 { name != nil } else { false } })
    }

    @Test("marks a wrong password unauthorized and stops retrying")
    func wrongPassword() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs", arguments: ["--password", "right"])
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: "wrong"),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .unauthorized })
    }

    @Test("reports disconnected when the daemon stops")
    func daemonStops() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        let port = try daemon.int("port")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: nil),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        daemon.stop()
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .disconnected })
    }
}
