import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostConnectionTests {
    @MainActor
    struct Harness {
        let clock = TestClock()
        let factory = FakeTransportFactory()
        let sink = RecordingSink()
        let connection: HostConnection

        init(entry: HostEntry = .directTcp(id: "h1", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: nil)) throws {
            connection = try HostConnection(entry: entry, sink: sink, clock: clock, transportFactory: factory.make)
        }

        var transport: FakeTransport { factory.last! }

        /// Finds the requestId of the last request of a given type the client sent.
        func requestId(ofType type: String) throws -> String {
            for text in transport.sentText.reversed() {
                let envelope = try jsonObject(text)
                guard let message = envelope["message"] as? [String: Any], message["type"] as? String == type else { continue }
                return try #require(message["requestId"] as? String)
            }
            Issue.record("no \(type) sent")
            throw NSError(domain: "HostConnectionTests", code: 1)
        }

        func openWithServerInfo(serverId: String = "srv-1", hostname: String? = "studio") {
            transport.simulateOpen()
            transport.simulateText(DaemonWire.serverInfo(serverId: serverId, hostname: hostname))
        }

        /// Answers both seed requests in the order the connection sends them.
        func answerSeed(agents: [String] = ["a1"], workspaces: [String] = ["w1"], agentsHasMore: Bool = false, workspacesHasMore: Bool = false) async throws {
            await settle()
            transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try requestId(ofType: "fetch_agents_request"), agents: agents, hasMore: agentsHasMore))
            await settle()
            transport.simulateText(DaemonWire.fetchWorkspacesResponse(requestId: try requestId(ofType: "fetch_workspaces_request"), workspaces: workspaces, hasMore: workspacesHasMore))
            await settle()
        }
    }

    @Test("registers the host before dialing and reports connecting")
    func registersHost() throws {
        let h = try Harness()
        #expect(h.sink.events.first == .setHost("h1", label: nil, endpointHint: "127.0.0.1:6767"))
        #expect(h.sink.statuses == [.connecting])
        #expect(h.transport.connectCalls == 1)
        #expect(h.transport.request.url.absoluteString == "ws://127.0.0.1:6767/ws")
    }

    @Test("dials the relay URL and no auth for a relay entry")
    func relayEntry() throws {
        let offer = ConnectionOffer(
            serverId: "srv-1",
            daemonPublicKeyB64: E2EEBox.exportPublicKey(E2EEBox.generateKeyPair().publicKey),
            relay: .init(endpoint: "relay.paseo.sh:443")
        )
        let h = try Harness(entry: .relay(id: "r1", label: "Studio", offer: offer))
        #expect(h.sink.events.first == .setHost("r1", label: "Studio", endpointHint: "relay.paseo.sh:443"))
        #expect(h.transport.request.url.absoluteString == "wss://relay.paseo.sh:443/ws?serverId=srv-1&role=client&v=2")
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
    }

    @Test("an entry that cannot form a URL throws before the host is registered")
    func invalidEntry() {
        let sink = RecordingSink()
        #expect(throws: DaemonEndpointError.self) {
            try HostConnection(
                entry: .directTcp(id: "bad", label: nil, endpoint: "nonsense", useTls: false, password: nil),
                sink: sink,
                clock: TestClock(),
                transportFactory: FakeTransportFactory().make
            )
        }
        #expect(sink.events.isEmpty)
    }

    @Test("seeds both lists together, records serverId and hostname, then reports connected")
    func seeds() async throws {
        let h = try Harness()
        h.openWithServerInfo(serverId: "srv-1", hostname: "studio")
        await settle()
        let agentsRequest = try jsonObject(try #require(h.transport.sentText.last))["message"] as? [String: Any]
        #expect(agentsRequest?["type"] as? String == "fetch_agents_request")
        #expect((agentsRequest?["sort"] as? [[String: String]]) == [
            ["key": "status_priority", "direction": "asc"],
            ["key": "updated_at", "direction": "desc"],
        ])
        #expect((agentsRequest?["page"] as? [String: Any])?["limit"] as? Int == 200)
        try await h.answerSeed(agents: ["a1", "a2"], workspaces: ["w1"])
        let seededFrom = try #require(h.sink.events.firstIndex(of: .seedAgents("h1", ids: ["a1", "a2"], truncated: false)))
        #expect(Array(h.sink.events[seededFrom...]) == [
            .seedAgents("h1", ids: ["a1", "a2"], truncated: false),
            .seedWorkspaces("h1", ids: ["w1"], truncated: false),
            .setServerId("h1", "srv-1"),
            .setHostname("h1", "studio"),
            .setStatus("h1", .connected),
        ])
        #expect(h.sink.statuses == [.connecting, .connected])
    }

    @Test("asks for workspaces sorted by status_priority only")
    func workspaceSort() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try h.requestId(ofType: "fetch_agents_request")))
        await settle()
        let request = try jsonObject(try #require(h.transport.sentText.last))["message"] as? [String: Any]
        #expect(request?["type"] as? String == "fetch_workspaces_request")
        #expect((request?["sort"] as? [[String: String]]) == [["key": "status_priority", "direction": "asc"]])
        #expect((request?["subscribe"] as? [String: Any])?.isEmpty == true)
    }

    @Test("carries each page's hasMore through as a visible cap")
    func truncation() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed(agentsHasMore: true, workspacesHasMore: true)
        #expect(h.sink.events.contains(.seedAgents("h1", ids: ["a1"], truncated: true)))
        #expect(h.sink.events.contains(.seedWorkspaces("h1", ids: ["w1"], truncated: true)))
    }

    @Test("leaves the hostname nil when the daemon does not report one")
    func noHostname() async throws {
        let h = try Harness()
        h.openWithServerInfo(hostname: nil)
        try await h.answerSeed()
        #expect(h.sink.events.contains(.setHostname("h1", nil)))
    }

    @Test("retries a failed seed after two seconds instead of pinning a live host at disconnected")
    func seedRetry() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        let first = try h.requestId(ofType: "fetch_agents_request")
        h.transport.simulateText(DaemonWire.rpcError(requestId: first, error: "busy"))
        await settle()
        #expect(h.sink.statuses == [.connecting, .disconnected])
        await h.clock.advance(by: .seconds(2))
        await settle()
        let second = try h.requestId(ofType: "fetch_agents_request")
        #expect(second != first)
        try await h.answerSeed()
        #expect(h.sink.statuses == [.connecting, .disconnected, .connected])
    }

    @Test("applies neither list when only the workspace seed fails")
    func partialSeedFails() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try h.requestId(ofType: "fetch_agents_request"), agents: ["a1"]))
        await settle()
        h.transport.simulateText(DaemonWire.rpcError(requestId: try h.requestId(ofType: "fetch_workspaces_request"), error: "busy"))
        await settle()
        #expect(!h.sink.events.contains { if case .seedAgents = $0 { true } else { false } })
        #expect(h.sink.statuses.last == .disconnected)
    }

    @Test("streams updates into the sink, reading removals from the right field")
    func streamsUpdates() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.transport.simulateText(DaemonWire.agentRemove(id: "a1"))
        h.transport.simulateText(DaemonWire.workspaceRemove(id: "w1"))
        #expect(h.sink.events.suffix(2) == [
            .agentUpdate("h1", .remove(agentId: "a1")),
            .workspaceUpdate("h1", .remove(id: "w1")),
        ])
    }

    @Test("reports disconnected when the daemon goes away and connecting on the retry")
    func disconnectAndRetry() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.transport.simulateClose(code: 1006, reason: "")
        #expect(h.sink.statuses.last == .disconnected)
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.sink.statuses.last == .connecting)
        #expect(h.factory.transports.count == 2)
    }

    @Test("classifies an auth rejection as unauthorized and stops retrying")
    func unauthorized() async throws {
        let h = try Harness(entry: .directTcp(id: "h1", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: "wrong"))
        h.transport.simulateOpen()
        h.transport.simulateClose(code: 4401, reason: "Incorrect password")
        #expect(h.sink.statuses == [.connecting, .unauthorized])
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1, "no reconnect behind backoff")
        #expect(h.sink.statuses == [.connecting, .unauthorized], "the disposed transition is not reported")
        #expect(!h.sink.events.contains(.removeHost("h1")), "the host stays visible")
    }

    @Test("close removes the host and disposes the session")
    func close() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.connection.close()
        #expect(h.sink.events.last == .removeHost("h1"))
        #expect(h.transport.closedWith?.code == 1000)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
    }
}
