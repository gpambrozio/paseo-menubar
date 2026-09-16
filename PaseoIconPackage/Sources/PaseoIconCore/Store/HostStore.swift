import Foundation

/// One host's replicated state. Two lists, because they answer two different
/// questions: `workspaces` is what the menu shows, the same unit and the same
/// daemon-computed bucket the Paseo sidebar renders, and `agents` exists only
/// to resolve a click, since there is no workspace deep link.
public struct HostSnapshot: Equatable, Sendable {
    public let hostId: String
    /// The user's explicit name from the registry. Nil when the entry has
    /// none. The raw value, not the resolved display name: see `resolveHostName`.
    public let label: String?
    /// The daemon's own hostname, from the live `server_info` message.
    public let hostname: String?
    /// The entry's own connection address, the last-resort name.
    public let endpointHint: String
    public let status: HostStatus
    public let serverId: String?
    public let workspaces: [WorkspaceDescriptor]
    public let agents: [AgentSnapshot]
    /// The host has more workspaces than the seed page could carry.
    public let workspacesTruncated: Bool
    /// The host has more agents than the seed page could carry.
    public let agentsTruncated: Bool
}

/// Replicated workspace and agent state, keyed by host. The `HostSink` a
/// `HostConnection` reports into, plus the configuration error the menu shows.
@MainActor
public final class HostStore: HostSink {
    private struct Entry {
        var label: String?
        var hostname: String?
        var endpointHint: String
        var status: HostStatus
        var serverId: String?
        var workspaces: [String: WorkspaceDescriptor] = [:]
        var agents: [String: AgentSnapshot] = [:]
        var workspacesTruncated = false
        var agentsTruncated = false
        /// Insertion order, so the menu's host rows follow config order rather
        /// than a dictionary's arbitrary one.
        var order: Int
    }

    private var hosts: [String: Entry] = [:]
    private var nextOrder = 0
    private var listeners: [UUID: () -> Void] = [:]
    private var configError: String?

    public init() {}

    /// A configuration problem the user has to fix. It rides in the store so
    /// the menu can show it: a modal error box steals focus from the app the
    /// user is fixing it in, and on its own leaves the tray showing an
    /// unexplained "No workspaces".
    public func setConfigError(_ message: String?) {
        guard configError != message else { return }
        configError = message
        emit()
    }

    public func getConfigError() -> String? { configError }

    public func setHost(_ hostId: String, label: String?, endpointHint: String) {
        if var existing = hosts[hostId] {
            existing.label = label
            existing.endpointHint = endpointHint
            hosts[hostId] = existing
        } else {
            hosts[hostId] = Entry(label: label, hostname: nil, endpointHint: endpointHint, status: .connecting, serverId: nil, order: nextOrder)
            nextOrder += 1
        }
        emit()
    }

    public func removeHost(_ hostId: String) {
        guard hosts.removeValue(forKey: hostId) != nil else { return }
        emit()
    }

    public func setStatus(_ hostId: String, _ status: HostStatus) {
        guard var host = hosts[hostId], host.status != status else { return }
        host.status = status
        hosts[hostId] = host
        emit()
    }

    public func setServerId(_ hostId: String, _ serverId: String) {
        guard var host = hosts[hostId], host.serverId != serverId else { return }
        host.serverId = serverId
        hosts[hostId] = host
        emit()
    }

    /// The daemon's own hostname, carried the same way `serverId` is.
    public func setHostname(_ hostId: String, _ hostname: String?) {
        guard var host = hosts[hostId], host.hostname != hostname else { return }
        host.hostname = hostname
        hosts[hostId] = host
        emit()
    }

    /// Replaces the host's agents wholesale: a subscription gap must not
    /// strand a dead row.
    public func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        guard var host = hosts[hostId] else { return }
        host.agents = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        host.agentsTruncated = truncated
        hosts[hostId] = host
        emit()
    }

    /// Replaces the host's workspaces wholesale. Same rule as `seedAgents`.
    public func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        guard var host = hosts[hostId] else { return }
        host.workspaces = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        host.workspacesTruncated = truncated
        hosts[hostId] = host
        emit()
    }

    public func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) {
        guard var host = hosts[hostId] else { return }
        switch update {
        case .upsert(let agent):
            host.agents[agent.id] = agent
        case .remove(let agentId):
            guard host.agents.removeValue(forKey: agentId) != nil else { return }
        }
        hosts[hostId] = host
        emit()
    }

    public func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) {
        guard var host = hosts[hostId] else { return }
        switch update {
        case .upsert(let workspace):
            host.workspaces[workspace.id] = workspace
        case .remove(let id):
            guard host.workspaces.removeValue(forKey: id) != nil else { return }
        }
        hosts[hostId] = host
        emit()
    }

    /// Hosts in the order they were registered, each with its lists in a
    /// stable order so the menu does not reshuffle between renders.
    public func snapshot() -> [HostSnapshot] {
        hosts.sorted { $0.value.order < $1.value.order }.map { hostId, host in
            HostSnapshot(
                hostId: hostId,
                label: host.label,
                hostname: host.hostname,
                endpointHint: host.endpointHint,
                status: host.status,
                serverId: host.serverId,
                workspaces: host.workspaces.values.sorted { $0.id < $1.id },
                agents: host.agents.values.sorted { $0.id < $1.id },
                workspacesTruncated: host.workspacesTruncated,
                agentsTruncated: host.agentsTruncated
            )
        }
    }

    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    private func emit() {
        for listener in listeners.values { listener() }
    }
}
