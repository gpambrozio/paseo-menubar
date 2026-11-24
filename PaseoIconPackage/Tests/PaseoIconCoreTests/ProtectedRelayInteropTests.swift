import Foundation
import Testing
@testable import PaseoIconCore

/// Actual upstream 0.17.3 daemon, encrypted through a relay that only forwards
/// frames. Uses temporary daemon storage and never connects to a saved host.
@MainActor
struct ProtectedRelayInteropTests {
    private func offer(_ harness: NodeHarness) throws -> ConnectionOffer {
        ConnectionOffer(
            serverId: try harness.string("serverId"),
            daemonPublicKeyB64: try harness.string("daemonPublicKeyB64"),
            relay: .init(endpoint: try harness.string("relayEndpoint"), useTls: false),
            minimumSecurityMode: .protected
        )
    }

    @Test("protected relay authenticates, seeds, reconnects and never leaks the password")
    func protectedRoundTrip() async throws {
        let harness = try await NodeHarness(script: "swift-test-protected-relay.mjs")
        defer { harness.stop() }
        let offer = try offer(harness)
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .relay(id: "protected-interop", label: nil, offer: offer, password: "isolated-relay-test-password"),
            sink: sink, clock: ContinuousClock()
        )
        defer { connection.close() }
        try #require(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        #expect(connection.relaySecurityMode == .protected)
        #expect(sink.events.contains(.setServerId("protected-interop", offer.serverId)))
        #expect(sink.events.contains(.seedAgents("protected-interop", ids: [], truncated: false)))
        #expect(sink.events.contains(.seedWorkspaces("protected-interop", ids: [], truncated: false)))

        let initialConnections = sink.statuses.filter { $0 == .connected }.count
        let endpoint = try harness.string("relayEndpoint")
        let disconnectURL = try #require(URL(string: "http://\(endpoint)/disconnect"))
        var request = URLRequest(url: disconnectURL)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        #expect(await eventually(timeout: .seconds(30)) {
            sink.statuses.filter { $0 == .connected }.count > initialConnections
        })
        #expect(connection.relaySecurityMode == .protected)
        let statsURL = try #require(URL(string: "http://\(endpoint)/stats"))
        let (data, _) = try await URLSession.shared.data(from: statsURL)
        let stats = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(stats["leakedCredential"] as? Bool == false)
        #expect((stats["clientConnections"] as? Int ?? 0) >= 2)
    }

    @Test("protected relay returns authenticated password rejection", arguments: ["", "incorrect-test-password"])
    func passwordRejection(password: String) async throws {
        let harness = try await NodeHarness(script: "swift-test-protected-relay.mjs")
        defer { harness.stop() }
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .relay(id: "rejected-interop", label: nil, offer: try offer(harness), password: password.isEmpty ? nil : password),
            sink: sink, clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .unauthorized })
        #expect(!sink.statuses.contains(.connected))
    }
}
