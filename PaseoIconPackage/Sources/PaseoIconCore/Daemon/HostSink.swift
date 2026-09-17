public enum HostStatus: String, Equatable, Sendable, CaseIterable {
    case connecting
    case connected
    case disconnected
    case unauthorized
    /// The entry itself is unusable, e.g. an endpoint that cannot form a URL.
    case invalid
}

/// What a connection reports into. The store that renders the menu implements
/// this in a later plan; tests use a recording fake. Every call is on the main actor.
@MainActor
public protocol HostSink: AnyObject {
    func setHost(_ hostId: String, label: String?, endpointHint: String)
    func removeHost(_ hostId: String)
    func setStatus(_ hostId: String, _ status: HostStatus)
    func setServerId(_ hostId: String, _ serverId: String)
    func setHostname(_ hostId: String, _ hostname: String?)
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool)
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool)
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate)
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate)
}

/// What the fleet holds: one host's connection, closable. `HostConnection` is
/// the only production conformance; the fleet depends on this so its
/// bookkeeping can be tested without a socket.
@MainActor
public protocol HostConnecting: AnyObject {
    func close()
}
