import Clocks
import CryptoKit
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct DaemonSessionTests {
    @MainActor
    struct Harness {
        let clock = TestClock()
        let factory = FakeTransportFactory()
        let session: DaemonSession
        private let stateLog = StateLog()

        @MainActor
        final class StateLog {
            var states: [ConnectionState] = []
        }

        init(password: String? = nil, e2eeKey: String? = nil, configure: (inout DaemonSessionConfig) -> Void = { _ in }) {
            var config = DaemonSessionConfig(
                url: URL(string: "ws://127.0.0.1:6767/ws")!,
                clientId: "paseo-menubar-test",
                appVersion: "0.4.0"
            )
            config.password = password
            config.e2eeDaemonPublicKeyB64 = e2eeKey
            configure(&config)
            session = DaemonSession(config: config, transportFactory: factory.make, clock: clock)
            _ = session.subscribeConnectionStatus { [stateLog] state in stateLog.states.append(state) }
        }

        var states: [ConnectionState] { stateLog.states }
        var transport: FakeTransport { factory.last! }

        /// Open the socket and deliver server_info, the two steps to `connected`.
        func connectFully(serverId: String = "srv-1") {
            session.connect()
            transport.simulateOpen()
            transport.simulateText(DaemonWire.serverInfo(serverId: serverId))
        }

        /// The session message of the last frame the client sent, decoded.
        func lastSentSessionMessage() throws -> [String: Any] {
            let envelope = try jsonObject(try #require(transport.sentText.last))
            #expect(envelope["type"] as? String == "session")
            return try #require(envelope["message"] as? [String: Any])
        }
    }

    @Test("dials with the password as bearer header and subprotocol")
    func passwordOnTheWire() {
        let h = Harness(password: " s3cret ")
        h.session.connect()
        #expect(h.transport.request.headers == ["Authorization": "Bearer s3cret"])
        #expect(h.transport.request.subprotocols == ["paseo.bearer.s3cret"])
        #expect(h.transport.connectCalls == 1)
    }

    @MainActor
    private final class LocalAuthSource {
        var token = "fixture-local-token-one"
        var reads = 0
        func read(url: URL) -> (url: URL, token: String) {
            reads += 1
            return (url, token)
        }
    }

    @Test("local credential supersedes a saved password and refreshes after reconnect")
    func localCredentialRefresh() async throws {
        let source = LocalAuthSource()
        let alias = try #require(URL(string: "ws://localhost:6767/ws"))
        let listener = try #require(URL(string: "ws://127.0.0.1:6767/ws"))
        let h = Harness(password: "outdated-password") {
            $0.url = alias
            $0.localCredential = { source.read(url: listener) }
            $0.localExpectedServerId = "srv-local"
        }
        h.session.connect()
        #expect(h.transport.request.url == listener)
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
        h.transport.simulateOpen()
        let hello = try jsonObject(try #require(h.transport.sentText.first))
        #expect(hello["auth"] as? [String: String] == ["kind": "localCredential", "token": source.token])
        #expect(!h.transport.sentText.joined().contains("outdated-password"))
        h.transport.simulateText(DaemonWire.serverInfo(serverId: "srv-local"))
        #expect(h.session.connectionState == .connected)
        source.token = "fixture-local-token-two"
        h.transport.simulateClose(code: 1006, reason: "test disconnect")
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        try #require(h.factory.transports.count == 2)
        h.transport.simulateOpen()
        let secondHello = try jsonObject(try #require(h.transport.sentText.first))
        #expect(secondHello["auth"] as? [String: String] == ["kind": "localCredential", "token": source.token])
        #expect(h.transport.request.headers.isEmpty)
        #expect(source.reads == 2)
    }

    @Test("a local credential is never requested for remote or relay connections", arguments: [false, true])
    func localCredentialStaysLocal(relay: Bool) throws {
        let source = LocalAuthSource()
        let relayKey = relay ? E2EEBox.exportPublicKey(try E2EEBox.generateKeyPair().publicKey) : nil
        let h = Harness(e2eeKey: relayKey) {
            if !relay { $0.url = URL(string: "wss://localhost.example.test/ws")! }
            let url = $0.url
            $0.localCredential = { source.read(url: url) }
        }
        h.session.connect()
        h.transport.simulateOpen()
        #expect(source.reads == 0)
        #expect(h.transport.request.headers.isEmpty)
        #expect(!h.transport.sentText.joined().contains(source.token))
    }

    @Test("a local credential source cannot redirect the connection off loopback")
    func refusesRemoteLocalCredentialDestination() throws {
        let remote = try #require(URL(string: "ws://example.test:6767/ws"))
        let h = Harness {
            $0.localCredential = { (remote, "fixture-local-token") }
        }
        h.session.connect()
        h.transport.simulateOpen()
        #expect(h.transport.request.url != remote)
        #expect(!h.transport.sentText.joined().contains("fixture-local-token"))
    }

    @Test("local authentication still requires the saved daemon identity before admission")
    func localDaemonIdentityMismatch() throws {
        let h = Harness {
            let url = $0.url
            $0.localCredential = { (url, "fixture-local-token") }
            $0.localExpectedServerId = "srv-local"
        }
        h.session.connect()
        h.transport.simulateOpen()
        h.transport.simulateText(DaemonWire.serverInfo(serverId: "srv-different"))
        #expect(h.session.securityFailureReason == "Local daemon identity did not match the saved host")
        #expect(!h.states.contains(.connected))
    }

    @Test("dials without auth when there is no password")
    func noPassword() {
        let h = Harness()
        h.session.connect()
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
    }

    @Test("sends hello on open with protocolVersion 1 and the capability set")
    func helloOnOpen() throws {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        let hello = try jsonObject(try #require(h.transport.sentText.first))
        #expect(hello["type"] as? String == "hello")
        #expect(hello["clientId"] as? String == "paseo-menubar-test")
        #expect(hello["clientType"] as? String == "cli")
        #expect(hello["protocolVersion"] as? Int == 1)
        #expect(hello["appVersion"] as? String == "0.4.0")
        let capabilities = try #require(hello["capabilities"] as? [String: Bool])
        #expect(capabilities == DaemonSession.defaultCapabilities)
        #expect(capabilities["selective_agent_timeline"] == true)
    }

    @Test("reports connected only once server_info arrives")
    func connectedOnServerInfo() {
        let h = Harness()
        h.session.connect()
        #expect(h.states == [.idle, .connecting(attempt: 0)])
        h.transport.simulateOpen()
        #expect(h.session.connectionState == .connecting(attempt: 0))
        h.transport.simulateText(DaemonWire.serverInfo(serverId: " srv-1 ", hostname: "studio"))
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastServerInfo == ServerInfo(serverId: "srv-1", hostname: "studio"))
    }

    @Test("a non-string hostname reads as nil")
    func hostnameLenient() {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        h.transport.simulateText(#"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"s","hostname":42}}}"#)
        #expect(h.session.lastServerInfo == ServerInfo(serverId: "s", hostname: nil))
    }

    @Test("times out a connect with no server_info, then backs off exponentially")
    func connectTimeoutAndBackoff() async {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .disconnected(reason: "Connection timed out"))
        #expect(h.factory.transports[0].closedWith?.code == 1001)
        await h.clock.advance(by: .milliseconds(1499))
        await settle()
        #expect(h.factory.transports.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await settle()
        #expect(h.factory.transports.count == 2)
        #expect(h.session.connectionState == .connecting(attempt: 1))
        await h.clock.advance(by: .seconds(15))
        await settle()
        await h.clock.advance(by: .seconds(3))
        await settle()
        #expect(h.factory.transports.count == 3, "second delay is 1.5s * 2")
    }

    @Test("a successful connect resets the backoff")
    func backoffResets() async {
        let h = Harness()
        h.session.connect()
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.factory.transports.count == 2)
        h.transport.simulateOpen()
        h.transport.simulateText(DaemonWire.serverInfo(serverId: "srv-1"))
        #expect(h.session.connectionState == .connected)
        h.transport.simulateClose(code: 1006, reason: "")
        #expect(h.session.connectionState == .disconnected(reason: "Transport closed (code 1006)"))
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.factory.transports.count == 3, "back to the base delay")
    }

    @Test("the reconnect delay is capped at 30 seconds")
    func backoffCap() async {
        let h = Harness()
        h.session.connect()
        // Attempts 0 through 4 time out; their delays are 1.5, 3, 6, 12, and 24 seconds.
        for delaySeconds in [1.5, 3.0, 6.0, 12.0, 24.0] {
            await settle()
            await h.clock.advance(by: .seconds(15))
            await settle()
            await h.clock.advance(by: .seconds(delaySeconds))
            await settle()
        }
        #expect(h.factory.transports.count == 6)
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .disconnected(reason: "Connection timed out"))
        await h.clock.advance(by: .seconds(29))
        await settle()
        #expect(h.factory.transports.count == 6, "1.5 s × 2^5 would be 48 s; the cap is 30 s")
        await h.clock.advance(by: .seconds(1))
        await settle()
        #expect(h.factory.transports.count == 7)
    }

    @Test("the close reason becomes the disconnected reason")
    func closeReason() {
        let h = Harness()
        h.connectFully()
        h.transport.simulateClose(code: 4401, reason: "Incorrect password")
        #expect(h.session.connectionState == .disconnected(reason: "Incorrect password"))
    }

    @Test("correlates a fetch response by requestId and decodes it")
    func fetchAgents() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(
                sort: [SortKey(key: "status_priority", direction: "asc")],
                pageLimit: 200,
                subscribe: true
            ))
        }
        await settle()
        let request = try h.lastSentSessionMessage()
        #expect(request["type"] as? String == "fetch_agents_request")
        let requestId = try #require(request["requestId"] as? String)
        #expect((request["page"] as? [String: Any])?["limit"] as? Int == 200)
        #expect((request["subscribe"] as? [String: Any])?.isEmpty == true)
        #expect((request["sort"] as? [[String: String]]) == [["key": "status_priority", "direction": "asc"]])
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: "someone-else", agents: ["x"]))
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: requestId, agents: ["a1", "a2"], hasMore: true))
        let response = try await task.value
        #expect(response.entries.map(\.agent.id) == ["a1", "a2"])
        #expect(response.pageInfo.hasMore)
        #expect(response.entries[0].agent.workspaceId == "ws-1")
    }

    @Test("omits subscribe when not asked for")
    func fetchWithoutSubscribe() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchWorkspaces(FetchWorkspacesOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        let request = try h.lastSentSessionMessage()
        #expect(request["type"] as? String == "fetch_workspaces_request")
        #expect(request["subscribe"] == nil)
        let requestId = try #require(request["requestId"] as? String)
        h.transport.simulateText(DaemonWire.fetchWorkspacesResponse(requestId: requestId, workspaces: ["w1"]))
        let response = try await task.value
        #expect(response.entries.map(\.id) == ["w1"])
        #expect(response.entries[0].bucket == .running)
        #expect(response.entries[0].diffStat == DiffStat(additions: 3, deletions: 1))
    }

    @Test("a fetch fails with a timeout when nothing answers")
    func fetchTimeout() async throws {
        // Shorter than the ping interval: past 35 seconds of silence the
        // liveness check reconnects first and fails the request with
        // connectionLost, which is the right outcome but not this test's.
        let h = Harness(configure: { $0.requestTimeout = .seconds(5) })
        h.connectFully()
        let task = Task {
            try await h.session.fetchWorkspaces(FetchWorkspacesOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        await h.clock.advance(by: .seconds(5))
        await settle()
        await #expect(throws: DaemonSessionError.timeout("fetch_workspaces_response")) { try await task.value }
    }

    @Test("rpc_error rejects the matching request")
    func rpcError() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        let requestId = try #require(try h.lastSentSessionMessage()["requestId"] as? String)
        h.transport.simulateText(DaemonWire.rpcError(requestId: requestId, error: "boom"))
        await #expect(throws: DaemonSessionError.rpcError("boom")) { try await task.value }
    }

    @Test("a disconnect fails requests in flight")
    func disconnectFailsRequests() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        h.transport.simulateClose(code: 1006, reason: "gone")
        await #expect(throws: DaemonSessionError.connectionLost("gone")) { try await task.value }
    }

    @Test("a fetch before connected fails immediately")
    func fetchBeforeConnected() async {
        let h = Harness()
        h.session.connect()
        await #expect(throws: DaemonSessionError.notConnected) {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
    }

    @Test("pings every 10 seconds and reconnects after two unanswered pings")
    func livenessReconnect() async {
        let h = Harness()
        h.connectFully()
        h.transport.clearSent()
        await settle()
        await h.clock.advance(by: .seconds(10))
        await settle()
        #expect(h.transport.sentText == [#"{"type":"ping"}"#])
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected, "one miss is tolerated")
        await h.clock.advance(by: .seconds(10))
        await settle()
        #expect(h.transport.sentText.count == 2)
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .disconnected(reason: "Liveness check timed out"))
        #expect(h.factory.transports[0].closedWith?.code == 1001)
    }

    @Test("a pong answers the ping and resets the failure count")
    func pongKeepsAlive() async {
        let h = Harness()
        h.connectFully()
        await settle()
        await h.clock.advance(by: .seconds(10))
        await settle()
        h.transport.simulateText(DaemonWire.pong)
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected)
        await h.clock.advance(by: .seconds(10))
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected, "a single miss after a pong is still one miss")
    }

    @Test("dispatches agent and workspace updates to listeners")
    func updates() {
        let h = Harness()
        h.connectFully()
        var agentUpdates: [AgentUpdate] = []
        var workspaceUpdates: [WorkspaceUpdate] = []
        _ = h.session.onAgentUpdate { agentUpdates.append($0) }
        _ = h.session.onWorkspaceUpdate { workspaceUpdates.append($0) }
        h.transport.simulateText(DaemonWire.agentUpsert(id: "a1", status: "idle"))
        h.transport.simulateText(DaemonWire.agentRemove(id: "a1"))
        h.transport.simulateText(DaemonWire.workspaceUpsert(id: "w1", status: "needs_input"))
        h.transport.simulateText(DaemonWire.workspaceRemove(id: "w1"))
        #expect(agentUpdates.count == 2)
        if case .upsert(let agent) = agentUpdates[0] {
            #expect(agent.id == "a1")
            #expect(agent.status == "idle")
        } else {
            Issue.record("expected upsert")
        }
        #expect(agentUpdates[1] == .remove(agentId: "a1"))
        #expect(workspaceUpdates.count == 2)
        if case .upsert(let workspace) = workspaceUpdates[0] {
            #expect(workspace.id == "w1")
            #expect(workspace.bucket == .needsInput)
        } else {
            Issue.record("expected upsert")
        }
        #expect(workspaceUpdates[1] == .remove(id: "w1"))
    }

    @Test("an unknown bucket decodes with bucket nil rather than failing")
    func unknownBucket() {
        let h = Harness()
        h.connectFully()
        var workspaceUpdates: [WorkspaceUpdate] = []
        _ = h.session.onWorkspaceUpdate { workspaceUpdates.append($0) }
        h.transport.simulateText(DaemonWire.workspaceUpsert(id: "w1", status: "brand_new_bucket"))
        guard case .upsert(let workspace)? = workspaceUpdates.first else {
            Issue.record("expected upsert")
            return
        }
        #expect(workspace.status == "brand_new_bucket")
        #expect(workspace.bucket == nil)
    }

    @Test("a null or scalar agent is rejected rather than taking the process down")
    func nullAgentUpsert() {
        // `ignoresUnknown` covers the field being *absent*, which the guard
        // always handled. These are the shapes that used to reach
        // `JSONSerialization.data(withJSONObject:)`: JSON `null` decodes to
        // `NSNull`, which is not nil, and encoding it raises an Objective-C
        // exception that no Swift catch can see. The evidence that this test
        // works is a crashed test process, not a failed expectation.
        let h = Harness()
        h.connectFully()
        var agentUpdates: [AgentUpdate] = []
        var workspaceUpdates: [WorkspaceUpdate] = []
        _ = h.session.onAgentUpdate { agentUpdates.append($0) }
        _ = h.session.onWorkspaceUpdate { workspaceUpdates.append($0) }
        for agent in ["null", "5", #""a-string""#, "[]", "true"] {
            h.transport.simulateText(#"{"type":"session","message":{"type":"agent_update","payload":{"kind":"upsert","agent":\#(agent)}}}"#)
        }
        for workspace in ["null", "5", "[]"] {
            h.transport.simulateText(#"{"type":"session","message":{"type":"workspace_update","payload":{"kind":"upsert","workspace":\#(workspace)}}}"#)
        }
        #expect(h.session.connectionState == .connected)
        #expect(agentUpdates.isEmpty)
        #expect(workspaceUpdates.isEmpty)
        #expect(h.session.lastError?.hasPrefix("Message validation failed") == true)
    }

    @Test("unknown and malformed messages are ignored, not fatal")
    func ignoresUnknown() {
        let h = Harness()
        h.connectFully()
        h.transport.simulateText(#"{"type":"session","message":{"type":"agent_stream","payload":{}}}"#)
        h.transport.simulateText(#"{"type":"session","message":{"type":"agent_update","payload":{"kind":"upsert"}}}"#)
        h.transport.simulateText("not json")
        h.transport.simulateBinary([1, 2, 3])
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastError?.hasPrefix("Message validation failed") == true)
    }

    @Test("close disposes the session and never reconnects")
    func closeDisposes() async {
        let h = Harness()
        h.connectFully()
        h.session.close()
        #expect(h.session.connectionState == .disposed)
        #expect(h.transport.closedWith == TransportClose(code: 1000, reason: "Client closed"))
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
        #expect(h.states.last == .disposed)
    }

    @Test("wraps the transport in an E2EE channel for relay hosts")
    func relayWrapsChannel() throws {
        let daemon = try E2EEBox.generateKeyPair()
        let h = Harness(e2eeKey: E2EEBox.exportPublicKey(daemon.publicKey))
        h.session.connect()
        h.transport.simulateOpen()
        let first = try jsonObject(try #require(h.transport.sentText.first))
        #expect(first["type"] as? String == "e2ee_hello")
        #expect(h.session.connectionState == .connecting(attempt: 0))
        let clientKey = try E2EEBox.importPublicKey(base64: try #require(first["key"] as? String))
        let shared = try E2EEBox.deriveSharedKey(ourSecretKey: daemon.secretKey, peerPublicKey: clientKey)
        h.transport.simulateText(#"{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true}}"#)
        let encryptedHello = try #require(h.transport.sentText.last)
        let hello = try jsonObject(String(decoding: try E2EEBox.decrypt([UInt8](try #require(Data(base64Encoded: encryptedHello))), with: shared), as: UTF8.self))
        #expect(hello["type"] as? String == "hello")
        let serverInfo = Data(try E2EEBox.encrypt(Array(DaemonWire.serverInfo(serverId: "relayed").utf8), with: shared)).base64EncodedString()
        h.transport.simulateText(serverInfo)
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastServerInfo?.serverId == "relayed")
    }

    @Test(arguments: [
        ("srv-1", true, "Daemon requires protected endpoint security"),
        ("wrong", false, "Relay daemon identity did not match the connection offer"),
        ("", false, "Relay daemon omitted its server identity"),
    ])
    func legacyRelayAdmission(serverId: String, protectedSupport: Bool, reason: String) async throws {
        let daemon = try E2EEBox.generateKeyPair()
        let h = Harness(e2eeKey: E2EEBox.exportPublicKey(daemon.publicKey)) {
            $0.e2eeExpectedServerId = "srv-1"
        }
        h.session.connect()
        h.transport.simulateOpen()
        let first = try jsonObject(try #require(h.transport.sentText.first))
        let clientKey = try E2EEBox.importPublicKey(base64: try #require(first["key"] as? String))
        let shared = try E2EEBox.deriveSharedKey(ourSecretKey: daemon.secretKey, peerPublicKey: clientKey)
        h.transport.simulateText(#"{"type":"e2ee_ready"}"#)
        let info = #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"\#(serverId)","features":{"relayProtectedSecurity":\#(protectedSupport)}}}}"#
        h.transport.simulateText(Data(try E2EEBox.encrypt(Array(info.utf8), with: shared)).base64EncodedString())
        #expect(h.session.securityFailureReason == reason)
        #expect(h.session.lastServerInfo == nil)
        #expect(!h.states.contains(.connected))
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.transports.count == 1)
    }

    @Test(arguments: [false, true])
    func protectedRequiredBeforeApplicationHello(passwordConfigured: Bool) async throws {
        let daemon = try E2EEBox.generateKeyPair()
        let h = Harness(password: passwordConfigured ? "test-password" : nil, e2eeKey: E2EEBox.exportPublicKey(daemon.publicKey)) {
            $0.e2eeMinimumSecurityMode = passwordConfigured ? .legacy : .protected
        }
        h.session.connect()
        h.transport.simulateOpen()
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
        #expect(!h.transport.request.url.absoluteString.contains("test-password"))
        h.transport.simulateText(#"{"type":"e2ee_ready"}"#)
        #expect(h.transport.sent.count == 1)
        #expect(h.session.securityFailureReason == "Daemon offered only legacy endpoint security")
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.transports.count == 1)
    }

    @Test(arguments: [
        (nil as String?, "password_required", "Password required"),
        (" test-password ", "incorrect_password", "Incorrect password"),
    ])
    func authenticatedRelayRejection(password: String?, rejection: String, reason: String) async throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = daemon.publicKey.rawRepresentation.base64EncodedString()
        let h = Harness(password: password, e2eeKey: publicKey)
        h.session.connect()
        h.transport.simulateOpen()
        #expect(h.transport.sent.count == 1)
        #expect(!h.transport.sentText.contains { $0.contains("test-password") })
        let secured = try completeProtectedHandshake(h.transport, daemon: daemon)
        let clientHello = try #require(h.transport.sent.last)
        guard case .text(let plaintext) = try secured.open(clientHello) else {
            Issue.record("Expected application hello")
            return
        }
        let hello = try jsonObject(plaintext)
        #expect(hello["type"] as? String == "hello")
        #expect((hello["capabilities"] as? [String: Bool])?["hello_rejection"] == true)
        if let password {
            #expect(hello["auth"] as? [String: String] == ["kind": "password", "password": password])
        } else {
            #expect(hello["auth"] == nil)
        }
        #expect(!h.transport.sentText.contains { $0.contains("test-password") })
        #expect(h.session.connectionState == .connecting(attempt: 0))

        let message = #"{"type":"hello.rejected","reason":"\#(rejection)","accepts":["password"]}"#
        h.transport.onFrame?(try secured.seal(.text(message)))
        #expect(h.session.connectionState == .disconnected(reason: reason))
        #expect(h.session.securityFailureReason == nil)
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.transports.count == 1)
    }

    @Test(arguments: [false, true])
    func protectedNegotiationRaisesReconnectFloor(tamperedRecord: Bool) async throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let h = Harness(e2eeKey: daemon.publicKey.rawRepresentation.base64EncodedString()) {
            $0.e2eeExpectedServerId = "srv-1"
        }
        var authenticatedModes: [RelaySecurityMode] = []
        h.session.onSecurityMode = { authenticatedModes.append($0) }
        h.session.connect()
        h.transport.simulateOpen()
        let secured = try completeProtectedHandshake(h.transport, daemon: daemon)
        #expect(h.session.relaySecurityMode == .protected)
        #expect(authenticatedModes == [.protected])
        #expect(h.session.connectionState == .connecting(attempt: 0))
        #expect(h.session.lastServerInfo == nil)
        if tamperedRecord {
            h.transport.onFrame?(try secured.seal(.text(DaemonWire.serverInfo(serverId: "srv-1"))))
            #expect(h.session.connectionState == .connected)
            guard case .binary(var record) = try secured.seal(.binary([1, 2, 3])) else {
                Issue.record("expected a protected binary record")
                return
            }
            record[try #require(record.indices.last)] ^= 1
            h.transport.onFrame?(.binary(record))
            #expect(h.session.securityFailureReason == nil)
            #expect(h.session.connectionState == .disconnected(reason: "Invalid protected relay record"))
        } else {
            h.transport.simulateClose(code: 1012, reason: "")
        }
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        try #require(h.factory.transports.count == 2)
        h.transport.simulateOpen()
        h.transport.simulateText(#"{"type":"e2ee_ready"}"#)
        #expect(h.transport.sent.count == 1)
        #expect(h.session.securityFailureReason == "Daemon offered only legacy endpoint security")
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.transports.count == 2)
    }

    @Test
    func rebuiltHostRequiresProtectedAfterDisconnectBeforeServerInfo() throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let offer = ConnectionOffer(
            serverId: "srv-1",
            daemonPublicKeyB64: daemon.publicKey.rawRepresentation.base64EncodedString(),
            relay: .init(endpoint: "relay.test:443")
        )
        let entry = HostEntry.relay(id: "r1", label: nil, offer: offer)
        let clock = TestClock()
        let factory = FakeTransportFactory()
        var persisted: [String] = []
        let firstPins = RelaySecurityPinStore(persistedIdentities: []) { persisted = $0 }
        let first = try HostConnection.makeSession(
            for: entry, clock: clock, relaySecurityPins: firstPins, transportFactory: factory.make
        )
        first.connect()
        let firstSocket = try #require(factory.last)
        firstSocket.simulateOpen()
        _ = try completeProtectedHandshake(firstSocket, daemon: daemon)
        #expect(first.connectionState == .connecting(attempt: 0))
        #expect(persisted.count == 1)
        firstSocket.simulateClose(code: 1012, reason: "")
        first.close()

        let sink = RecordingSink()
        let reopenedPins = RelaySecurityPinStore(persistedIdentities: persisted) { persisted = $0 }
        let rebuilt = try HostConnection(
            entry: entry, sink: sink, clock: clock, relaySecurityPins: reopenedPins, transportFactory: factory.make
        )
        defer { rebuilt.close() }
        let rebuiltSocket = try #require(factory.last)
        rebuiltSocket.simulateOpen()
        rebuiltSocket.simulateText(#"{"type":"e2ee_ready"}"#)
        #expect(sink.statuses.last == .securityRejected)
        #expect(rebuiltSocket.sent.count == 1)
    }

    @Test
    func unauthenticatedProtectedReadyNeverSendsCredentials() async throws {
        let daemon = Curve25519.KeyAgreement.PrivateKey()
        let h = Harness(password: "test-password", e2eeKey: daemon.publicKey.rawRepresentation.base64EncodedString())
        h.session.connect()
        h.transport.simulateOpen()
        _ = try completeProtectedHandshake(h.transport, daemon: daemon, tamperReply: true)
        h.transport.simulateText(#"{"type":"e2ee_ready"}"#)
        #expect(h.transport.sent.count == 1)
        #expect(h.session.relaySecurityMode == nil)
        #expect(h.session.connectionState == .disconnected(reason: "Could not authenticate protected relay handshake"))
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.transports.count == 1)
    }

    /// The test daemon's Noise NK responder. It uses independent HKDF plus the
    /// production record codec to give the fake socket real wire frames.
    private func completeProtectedHandshake(
        _ transport: FakeTransport,
        daemon: Curve25519.KeyAgreement.PrivateKey,
        tamperReply: Bool = false
    ) throws -> ProtectedRecordCodec {
        let hello = try jsonObject(try #require(transport.sentText.first))
        let envelope = try #require(hello["protected"] as? [String: Any])
        let encoded = try #require(envelope["message"] as? String)
        let message = Array(try #require(Data(base64Encoded: encoded)))
        let clientEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32))
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let daemonEphemeral = ephemeral.publicKey.rawRepresentation
        let protocolName = Data("Noise_NK_25519_ChaChaPoly_SHA256".utf8)
        var hash = protocolName
        var chainingKey = protocolName
        func mixHash(_ data: Data) { hash = Data(SHA256.hash(data: hash + data)) }
        func deriveKeys(_ secret: Data) -> (Data, SymmetricKey) {
            let extracted = HMAC<SHA256>.authenticationCode(for: secret, using: SymmetricKey(data: chainingKey))
            let output = HKDF<SHA256>.expand(pseudoRandomKey: extracted, info: Data(), outputByteCount: 64)
            let bytes = output.withUnsafeBytes { Data($0) }
            return (bytes.prefix(32), SymmetricKey(data: bytes.suffix(32)))
        }
        mixHash(Data("paseo-relay-e2ee/1".utf8))
        mixHash(daemon.publicKey.rawRepresentation)
        mixHash(clientEphemeral.rawRepresentation)
        let es = try daemon.sharedSecretFromKeyAgreement(with: clientEphemeral).withUnsafeBytes { Data($0) }
        let (ck1, key1) = deriveKeys(es)
        chainingKey = ck1
        var reader = NoiseCipherState(key: key1)
        let offered = try reader.open(message.dropFirst(32), authenticating: hash)
        mixHash(Data(message.dropFirst(32)))
        mixHash(daemonEphemeral)
        let ee = try ephemeral.sharedSecretFromKeyAgreement(with: clientEphemeral).withUnsafeBytes { Data($0) }
        let (ck2, key2) = deriveKeys(ee)
        chainingKey = ck2
        var writer = NoiseCipherState(key: key2)
        var reply = try writer.seal(offered, authenticating: hash)
        if tamperReply, let index = reply.indices.last { reply[index] ^= 1 }
        let (receive, send) = deriveKeys(Data())
        let wire = (daemonEphemeral + Data(reply)).base64EncodedString()
        transport.simulateText(#"{"type":"e2ee_ready","protected":{"v":1,"message":"\#(wire)"}}"#)
        return ProtectedRecordCodec(
            sender: NoiseCipherState(key: send),
            receiver: NoiseCipherState(key: SymmetricKey(data: receive)),
            binaryCiphertext: true
        )
    }

    @Test("a fatal E2EE frame disconnects the session at once and reconnects after the base delay")
    func relayFatalFrameReconnects() async throws {
        let daemon = try E2EEBox.generateKeyPair()
        let h = Harness(e2eeKey: E2EEBox.exportPublicKey(daemon.publicKey))
        h.session.connect()
        let first = h.transport
        first.simulateOpen()
        let hello = try jsonObject(try #require(first.sentText.first))
        let clientKey = try E2EEBox.importPublicKey(base64: try #require(hello["key"] as? String))
        let shared = try E2EEBox.deriveSharedKey(ourSecretKey: daemon.secretKey, peerPublicKey: clientKey)
        first.simulateText(#"{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true}}"#)
        let serverInfo = Data(try E2EEBox.encrypt(Array(DaemonWire.serverInfo(serverId: "relayed").utf8), with: shared)).base64EncodedString()
        first.simulateText(serverInfo)
        #expect(h.session.connectionState == .connected)

        first.simulateText(#"{"type":"session","message":{"type":"pong"}}"#)
        #expect(h.session.connectionState == .disconnected(reason: "Received plaintext frame on encrypted channel"))
        #expect(first.closedWith?.code == 1011)
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.factory.transports.count == 2, "reconnects after the base delay, not after two liveness timeouts")
    }

    @Test("an invalid daemon key gives up without retrying")
    func invalidKeyGivesUp() async {
        let h = Harness(e2eeKey: "AAAA")
        h.session.connect()
        #expect(h.session.connectionState == .disconnected(reason: "Invalid daemon public key"))
        #expect(h.transport.connectCalls == 0)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
    }
}
