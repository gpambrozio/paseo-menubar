import Foundation

public struct DaemonSessionConfig: Sendable {
    public var url: URL
    public var clientId: String
    public var clientType: String = "cli"
    public var appVersion: String
    public var password: String? = nil
    /// Set for relay hosts. Wraps the transport in `E2EEChannel`.
    public var e2eeDaemonPublicKeyB64: String? = nil
    public var capabilities: [String: Bool] = DaemonSession.defaultCapabilities
    public var connectTimeout: Duration = .seconds(15)
    public var reconnectBaseDelay: Duration = .milliseconds(1500)
    public var reconnectMaxDelay: Duration = .seconds(30)
    public var pingInterval: Duration = .seconds(10)
    public var pingTimeout: Duration = .seconds(15)
    public var livenessFailureThreshold: Int = 2
    public var requestTimeout: Duration = .seconds(60)

    public init(url: URL, clientId: String, appVersion: String) {
        self.url = url
        self.clientId = clientId
        self.appVersion = appVersion
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    case disconnected(reason: String?)
    case disposed
}

public enum DaemonSessionError: Error, Equatable {
    case notConnected
    case connectionLost(String?)
    case timeout(String)
    case rpcError(String)
    case disposed
}

/// The slice of `@getpaseo/client` 0.4.0 `DaemonClient` this app needs, on
/// the wire rather than through the SDK:
///
/// - connect, send `hello`, and report `connected` only once `server_info`
///   arrives (the relay accepts a socket even when the daemon is offline);
/// - a connect timeout, then exponential backoff between attempts;
/// - a `ping` every `pingInterval` once connected, a reconnect after
///   `livenessFailureThreshold` unanswered pings (relay sockets go half-open);
/// - `fetch_*_request` correlated by `requestId`, with a timeout;
/// - the `agent_update` and `workspace_update` streams.
///
/// Every callback fires on the main actor. Timers use the injected clock so
/// tests drive them with `TestClock`.
@MainActor
public final class DaemonSession {
    /// The set the 0.4.0 client advertises, plus `selective_agent_timeline`:
    /// without it the daemon streams every agent's timeline (`agent_stream`)
    /// to this client, which never views a timeline. With it, only
    /// `agent_attention_required` events arrive, which matters through a relay.
    nonisolated public static let defaultCapabilities: [String: Bool] = [
        "custom_mode_icons": true,
        "reasoning_merge_enum": true,
        "terminal_reflowable_snapshot": true,
        "provider_subagents": true,
        "project_updates": true,
        "compact_provider_snapshots": true,
        "selective_agent_timeline": true,
    ]

    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var lastServerInfo: ServerInfo?
    public private(set) var lastError: String?

    private struct PendingRequest {
        let expectedType: String
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    @MainActor
    private final class PingProbe {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func settle(_ ok: Bool) {
            guard result == nil else { return }
            result = ok
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: ok)
            }
        }

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private let config: DaemonSessionConfig
    private let transportFactory: TransportFactory
    private let clock: any Clock<Duration>
    private var transport: (any DaemonTransport)?
    private var shouldReconnect = true
    private var reconnectAttempt = 0
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var pingProbe: PingProbe?
    private var consecutiveLivenessFailures = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var statusListeners: [UUID: (ConnectionState) -> Void] = [:]
    private var agentListeners: [UUID: (AgentUpdate) -> Void] = [:]
    private var workspaceListeners: [UUID: (WorkspaceUpdate) -> Void] = [:]

    public init(config: DaemonSessionConfig, transportFactory: @escaping TransportFactory, clock: any Clock<Duration>) {
        self.config = config
        self.transportFactory = transportFactory
        self.clock = clock
    }

    // MARK: - Lifecycle

    public func connect() {
        guard connectionState != .disposed else { return }
        shouldReconnect = true
        attemptConnect()
    }

    /// Ends the session for good: no reconnect, pending requests fail with
    /// `.disposed`, listeners see `.disposed` once.
    public func close() {
        guard connectionState != .disposed else { return }
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopLiveness()
        failPendingRequests(DaemonSessionError.disposed)
        disposeTransport(code: 1000, reason: "Client closed")
        setState(.disposed)
    }

    // MARK: - Subscriptions

    /// Fires once immediately with the current state, then on every transition.
    public func subscribeConnectionStatus(_ listener: @escaping (ConnectionState) -> Void) -> () -> Void {
        let id = UUID()
        statusListeners[id] = listener
        listener(connectionState)
        return { [weak self] in self?.statusListeners[id] = nil }
    }

    public func onAgentUpdate(_ listener: @escaping (AgentUpdate) -> Void) -> () -> Void {
        let id = UUID()
        agentListeners[id] = listener
        return { [weak self] in self?.agentListeners[id] = nil }
    }

    public func onWorkspaceUpdate(_ listener: @escaping (WorkspaceUpdate) -> Void) -> () -> Void {
        let id = UUID()
        workspaceListeners[id] = listener
        return { [weak self] in self?.workspaceListeners[id] = nil }
    }

    // MARK: - Requests

    public func fetchAgents(_ options: FetchAgentsOptions) async throws -> FetchAgentsResponsePayload {
        let requestId = Self.makeRequestId()
        let message = FetchRequestMessage(
            type: "fetch_agents_request",
            requestId: requestId,
            sort: options.sort,
            page: .init(limit: options.pageLimit),
            subscribe: options.subscribe ? EmptyObject() : nil
        )
        let payload = try await sendRequest(message, requestId: requestId, expectedType: "fetch_agents_response")
        return try JSONDecoder().decode(FetchAgentsResponsePayload.self, from: payload)
    }

    public func fetchWorkspaces(_ options: FetchWorkspacesOptions) async throws -> FetchWorkspacesResponsePayload {
        let requestId = Self.makeRequestId()
        let message = FetchRequestMessage(
            type: "fetch_workspaces_request",
            requestId: requestId,
            sort: options.sort,
            page: .init(limit: options.pageLimit),
            subscribe: options.subscribe ? EmptyObject() : nil
        )
        let payload = try await sendRequest(message, requestId: requestId, expectedType: "fetch_workspaces_response")
        return try JSONDecoder().decode(FetchWorkspacesResponsePayload.self, from: payload)
    }

    // MARK: - Connecting

    private func attemptConnect() {
        guard connectionState != .disposed, shouldReconnect else { return }
        if case .connecting = connectionState { return }
        // An armed backoff timer has to go before a new attempt starts. The
        // guard above only covers `.connecting`, so a caller invoking the public
        // `connect()` while the state is `.disconnected` would leave the timer
        // running: it fires later, passes its own guards, and disposes the
        // transport that has meanwhile reached `.connected`, dropping the seed.
        reconnectTask?.cancel()
        reconnectTask = nil

        var headers: [String: String] = [:]
        var subprotocols: [String] = []
        if let password = config.password?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            headers["Authorization"] = "Bearer \(password)"
            subprotocols = ["paseo.bearer.\(password)"]
        }

        disposeTransport(code: 1001, reason: "Reconnecting")
        let base = transportFactory(TransportRequest(url: config.url, headers: headers, subprotocols: subprotocols))
        let transport: any DaemonTransport
        if let key = config.e2eeDaemonPublicKeyB64 {
            do {
                transport = try E2EEChannel(base: base, daemonPublicKeyB64: key, clock: clock)
            } catch {
                // An offer with a malformed key can never connect; retrying it
                // behind backoff forever is the failure mode to avoid.
                shouldReconnect = false
                lastError = "Invalid daemon public key: \(error)"
                setState(.disconnected(reason: "Invalid daemon public key"))
                return
            }
        } else {
            transport = base
        }
        self.transport = transport
        lastServerInfo = nil
        setState(.connecting(attempt: reconnectAttempt))
        armConnectTimeout()

        transport.onOpen = { [weak self] in self?.handleTransportOpen() }
        transport.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        transport.onClose = { [weak self] close in self?.handleTransportClose(close) }
        transport.onError = { [weak self] message in self?.lastError = message }
        transport.connect()
    }

    private func armConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.config.connectTimeout)
            } catch {
                return
            }
            guard case .connecting = self.connectionState else { return }
            self.lastError = "Connection timed out"
            self.disposeTransport(code: 1001, reason: "Connection timed out")
            self.scheduleReconnect(reason: "Connection timed out")
        }
    }

    private func handleTransportOpen() {
        let hello = HelloMessage(
            clientId: config.clientId,
            clientType: config.clientType,
            protocolVersion: 1,
            appVersion: config.appVersion,
            capabilities: config.capabilities
        )
        guard let transport, let data = try? JSONEncoder().encode(hello) else {
            scheduleReconnect(reason: "Failed to send hello message")
            return
        }
        transport.send(.text(String(decoding: data, as: UTF8.self)))
    }

    private func handleTransportClose(_ close: TransportClose) {
        let reason = close.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let described = reason.isEmpty ? "Transport closed (code \(close.code))" : reason
        lastError = described
        scheduleReconnect(reason: described)
    }

    private func handleFrame(_ frame: TransportFrame) {
        // Binary frames carry terminal and file-transfer data this client never asks for.
        guard case .text(let text) = frame else { return }
        let message: InboundMessage
        do {
            message = try InboundParser.parse(text)
        } catch {
            lastError = "Message validation failed: \(error)"
            return
        }
        consecutiveLivenessFailures = 0
        switch message {
        case .pong:
            pingProbe?.settle(true)
        case .serverInfo(let info):
            lastServerInfo = info
            if case .connecting = connectionState {
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
                reconnectAttempt = 0
                setState(.connected)
                startLiveness()
            }
        case .agentUpdate(let update):
            for listener in agentListeners.values { listener(update) }
        case .workspaceUpdate(let update):
            for listener in workspaceListeners.values { listener(update) }
        case .response(let requestId, let type, let payload):
            guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
            pending.timeoutTask.cancel()
            if pending.expectedType == type {
                pending.continuation.resume(returning: payload)
            } else {
                pending.continuation.resume(throwing: DaemonSessionError.rpcError("Unexpected response type \(type)"))
            }
        case .rpcError(let requestId, let error):
            rejectPending(requestId, DaemonSessionError.rpcError(error))
        case .other:
            return
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(reason: String?) {
        guard connectionState != .disposed else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopLiveness()
        failPendingRequests(DaemonSessionError.connectionLost(reason))
        disposeTransport(code: 1001, reason: "Reconnecting")
        setState(.disconnected(reason: reason))
        guard shouldReconnect else { return }
        armReconnectTimer()
    }

    private func armReconnectTimer() {
        let attempt = reconnectAttempt
        let factor = 1 << min(attempt, 20)
        let delay = min(config.reconnectBaseDelay * factor, config.reconnectMaxDelay)
        reconnectAttempt = attempt + 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: delay)
            } catch {
                return
            }
            guard self.shouldReconnect, self.connectionState != .disposed else { return }
            self.attemptConnect()
        }
    }

    // MARK: - Liveness

    private func startLiveness() {
        stopLiveness()
        consecutiveLivenessFailures = 0
        livenessTask = Task { [weak self] in
            while true {
                guard let self, self.connectionState == .connected else { return }
                do {
                    try await self.clock.sleep(for: self.config.pingInterval)
                } catch {
                    return
                }
                guard self.connectionState == .connected else { return }
                await self.runPingProbe()
            }
        }
    }

    private func stopLiveness() {
        livenessTask?.cancel()
        livenessTask = nil
        pingProbe?.settle(false)
        pingProbe = nil
    }

    private func runPingProbe() async {
        guard let transport else { return }
        let probe = PingProbe()
        pingProbe = probe
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.config.pingTimeout)
            } catch {
                return
            }
            probe.settle(false)
        }
        transport.send(.text(#"{"type":"ping"}"#))
        let answered = await probe.wait()
        timeoutTask.cancel()
        if pingProbe === probe { pingProbe = nil }
        guard connectionState == .connected else { return }
        if answered {
            consecutiveLivenessFailures = 0
            return
        }
        consecutiveLivenessFailures += 1
        guard consecutiveLivenessFailures >= config.livenessFailureThreshold else { return }
        consecutiveLivenessFailures = 0
        lastError = "Liveness check timed out"
        disposeTransport(code: 1001, reason: "Liveness timeout")
        scheduleReconnect(reason: "Liveness check timed out")
    }

    // MARK: - Requests plumbing

    private func sendRequest(_ message: some Encodable, requestId: String, expectedType: String) async throws -> Data {
        guard connectionState == .connected, let transport else { throw DaemonSessionError.notConnected }
        let data = try JSONEncoder().encode(SessionEnvelope(message: message))
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.clock.sleep(for: self.config.requestTimeout)
                } catch {
                    return
                }
                self.rejectPending(requestId, DaemonSessionError.timeout(expectedType))
            }
            pendingRequests[requestId] = PendingRequest(
                expectedType: expectedType,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            transport.send(.text(text))
        }
    }

    private func rejectPending(_ requestId: String, _ error: DaemonSessionError) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failPendingRequests(_ error: DaemonSessionError) {
        let pending = pendingRequests
        pendingRequests = [:]
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    private func disposeTransport(code: Int, reason: String) {
        guard let old = transport else { return }
        transport = nil
        old.onOpen = nil
        old.onFrame = nil
        old.onClose = nil
        old.onError = nil
        old.close(code: code, reason: reason)
    }

    private func setState(_ state: ConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        for listener in statusListeners.values { listener(state) }
    }

    private static func makeRequestId() -> String {
        UUID().uuidString.lowercased()
    }
}
