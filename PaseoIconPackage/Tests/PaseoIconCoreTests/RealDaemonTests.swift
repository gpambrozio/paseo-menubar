import Foundation
import Testing
@testable import PaseoIconCore

/// Against a real `@getpaseo/server` 0.4.0 daemon booted by
/// `scripts/swift-test-daemon.mjs`. Slow by design; the daemon takes a few
/// seconds to start.
@MainActor
struct RealDaemonTests {
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
