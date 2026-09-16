import Foundation

/// Owns one host: connect, seed, subscribe, and keep the sink's view of this
/// host's status honest. A port of `src/daemon/host-connection.ts`.
///
/// Seeding doubles as the daemon's required handshake: each stream only
/// starts once its own fetch has asked for it, so `agent_update` needs
/// `fetch_agents_request` and `workspace_update` needs `fetch_workspaces_request`.
@MainActor
public final class HostConnection: HostConnecting {
    public static let agentPageLimit = 200
    public static let workspacePageLimit = 200
    public static let seedRetryDelay: Duration = .seconds(2)
    /// The protocol series this client mirrors; sent as `appVersion` in `hello`.
    public static let advertisedAppVersion = "0.4.0"
    /// Exact close reasons the daemon sends when the bearer token is missing or
    /// wrong (`attachAuthenticatedSocket`, websocket-server.js). They surface as
    /// the `disconnected` reason, never as a thrown error.
    public static let authRejectionReasons: Set<String> = ["Password required", "Incorrect password"]

    private let entry: HostEntry
    private let sink: any HostSink
    private let clock: any Clock<Duration>
    private let session: DaemonSession
    private var closed = false
    private var seedRetryTask: Task<Void, Never>?
    private var unsubscribeStatus: (() -> Void)?
    private var unsubscribeAgents: (() -> Void)?
    private var unsubscribeWorkspaces: (() -> Void)?

    /// Throws before the host is registered with the sink when the entry cannot
    /// form a URL, so a host with no connection that owns it never appears.
    public init(
        entry: HostEntry,
        sink: any HostSink,
        clock: any Clock<Duration>,
        transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport(request: $0) }
    ) throws {
        self.entry = entry
        self.sink = sink
        self.clock = clock
        self.session = try Self.makeSession(for: entry, clock: clock, transportFactory: transportFactory)
        sink.setHost(entry.id, label: entry.label, endpointHint: entry.endpointHint)

        unsubscribeAgents = session.onAgentUpdate { [weak self] update in
            guard let self else { return }
            self.sink.applyAgentUpdate(self.entry.id, update)
        }
        unsubscribeWorkspaces = session.onWorkspaceUpdate { [weak self] update in
            guard let self else { return }
            self.sink.applyWorkspaceUpdate(self.entry.id, update)
        }
        unsubscribeStatus = session.subscribeConnectionStatus { [weak self] state in
            self?.handleStatus(state)
        }
        session.connect()
    }

    public static func makeSession(
        for entry: HostEntry,
        clock: any Clock<Duration>,
        transportFactory: @escaping TransportFactory
    ) throws -> DaemonSession {
        // Stable across launches: the daemon keys live-session resume by clientId.
        let clientId = "paseo-menubar-\(entry.id)"
        switch entry {
        case .directTcp(_, _, let endpoint, let useTls, let password):
            let url = try DaemonEndpoints.daemonWebSocketURL(endpoint: endpoint, useTls: useTls)
            var config = DaemonSessionConfig(url: url, clientId: clientId, appVersion: advertisedAppVersion)
            config.password = password
            return DaemonSession(config: config, transportFactory: transportFactory, clock: clock)
        case .relay(_, _, let offer):
            let useTls = offer.relay.useTls ?? DaemonEndpoints.shouldUseTlsForDefaultHostedRelay(offer.relay.endpoint)
            let url = try DaemonEndpoints.relayWebSocketURL(
                endpoint: offer.relay.endpoint,
                useTls: useTls,
                serverId: offer.serverId
            )
            var config = DaemonSessionConfig(url: url, clientId: clientId, appVersion: advertisedAppVersion)
            config.e2eeDaemonPublicKeyB64 = offer.daemonPublicKeyB64
            return DaemonSession(config: config, transportFactory: transportFactory, clock: clock)
        }
    }

    /// Closes the session and removes the host from the sink.
    public func close() {
        closed = true
        clearSeedRetry()
        unsubscribeAll()
        session.close()
        sink.removeHost(entry.id)
    }

    // MARK: - Status

    private func handleStatus(_ state: ConnectionState) {
        guard !closed else { return }
        switch state {
        case .idle:
            return
        case .connecting:
            sink.setStatus(entry.id, .connecting)
        case .connected:
            requestSeed()
        case .disconnected(let reason):
            clearSeedRetry()
            if let reason, Self.authRejectionReasons.contains(reason) {
                sink.setStatus(entry.id, .unauthorized)
                stopRetrying()
                return
            }
            sink.setStatus(entry.id, .disconnected)
        case .disposed:
            clearSeedRetry()
            sink.setStatus(entry.id, .disconnected)
        }
    }

    /// A wrong password retried behind backoff forever is the failure mode to
    /// avoid. The host stays in the sink as `unauthorized` until `close()`.
    private func stopRetrying() {
        guard !closed else { return }
        closed = true
        clearSeedRetry()
        unsubscribeAll()
        session.close()
    }

    // MARK: - Seeding

    /// Seeds, and keeps trying while the socket stays up. A failed seed leaves
    /// a live connection with no lists, which reports as `disconnected`
    /// because the app cannot vouch for agents it never fetched.
    private func requestSeed() {
        clearSeedRetry()
        // Deferred so seeding never re-enters the session from inside its own listener.
        Task { [weak self] in
            guard let self, !self.closed, self.session.connectionState == .connected else { return }
            do {
                try await self.seed()
            } catch {
                guard !self.closed else { return }
                self.sink.setStatus(self.entry.id, .disconnected)
                guard self.session.connectionState == .connected else { return }
                self.seedRetryTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.clock.sleep(for: Self.seedRetryDelay)
                    } catch {
                        return
                    }
                    self.seedRetryTask = nil
                    self.requestSeed()
                }
            }
        }
    }

    private func seed() async throws {
        // `status_priority` ascending puts the agents that drive the icon at the
        // front of a capped page; `updated_at` is the daemon's default tiebreaker.
        let agents = try await session.fetchAgents(FetchAgentsOptions(
            sort: [SortKey(key: "status_priority", direction: "asc"), SortKey(key: "updated_at", direction: "desc")],
            pageLimit: Self.agentPageLimit,
            subscribe: true
        ))
        // No secondary key: the daemon's own ordering decides the rest.
        let workspaces = try await session.fetchWorkspaces(FetchWorkspacesOptions(
            sort: [SortKey(key: "status_priority", direction: "asc")],
            pageLimit: Self.workspacePageLimit,
            subscribe: true
        ))
        guard !closed else { return }
        // Both lists land together, after both fetches resolved. Caps are
        // visible, never silent: `hasMore` rides through as `truncated`.
        sink.seedAgents(entry.id, agents.entries.map(\.agent), truncated: agents.pageInfo.hasMore)
        sink.seedWorkspaces(entry.id, workspaces.entries, truncated: workspaces.pageInfo.hasMore)
        if let info = session.lastServerInfo {
            sink.setServerId(entry.id, info.serverId)
            sink.setHostname(entry.id, info.hostname)
        }
        sink.setStatus(entry.id, .connected)
    }

    private func clearSeedRetry() {
        seedRetryTask?.cancel()
        seedRetryTask = nil
    }

    private func unsubscribeAll() {
        unsubscribeStatus?()
        unsubscribeAgents?()
        unsubscribeWorkspaces?()
        unsubscribeStatus = nil
        unsubscribeAgents = nil
        unsubscribeWorkspaces = nil
    }
}
