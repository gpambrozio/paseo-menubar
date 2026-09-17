import Foundation
import Testing
@testable import PaseoIconCore

/// The full relay path: a local relay under `wrangler dev`, a real daemon
/// registered with it, and this client dialing through it with E2EE. Opt-in
/// because it needs `scripts/relay-harness` installed and takes a minute:
///
///     PASEO_ICON_RELAY_E2E=1 swift test --filter RelayEndToEndTests
@MainActor
struct RelayEndToEndTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["PASEO_ICON_RELAY_E2E"] == "1" }

    @Test("connects through a relay with E2EE and seeds", .enabled(if: enabled))
    func relayRoundTrip() async throws {
        let harness = try await NodeHarness(script: "swift-test-relay.mjs")
        defer { harness.stop() }
        let offer = ConnectionOffer(
            serverId: try harness.string("serverId"),
            daemonPublicKeyB64: try harness.string("daemonPublicKeyB64"),
            relay: .init(endpoint: try harness.string("relayEndpoint"), useTls: false)
        )
        let sink = RecordingSink()
        let connection = try HostConnection(entry: .relay(id: "relayed", label: nil, offer: offer), sink: sink, clock: ContinuousClock())
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(60)) { sink.statuses.last == .connected })
        #expect(sink.events.contains(.setServerId("relayed", offer.serverId)))
        #expect(sink.events.contains(.seedWorkspaces("relayed", ids: [], truncated: false)))
    }
}
