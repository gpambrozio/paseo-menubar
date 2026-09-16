@testable import PaseoIconCore

@MainActor
final class RecordingSink: HostSink {
    enum Event: Equatable {
        case setHost(String, label: String?, endpointHint: String)
        case removeHost(String)
        case setStatus(String, HostStatus)
        case setServerId(String, String)
        case setHostname(String, String?)
        case seedAgents(String, ids: [String], truncated: Bool)
        case seedWorkspaces(String, ids: [String], truncated: Bool)
        case agentUpdate(String, AgentUpdate)
        case workspaceUpdate(String, WorkspaceUpdate)
    }

    private(set) var events: [Event] = []

    var statuses: [HostStatus] {
        events.compactMap { if case .setStatus(_, let status) = $0 { status } else { nil } }
    }

    func setHost(_ hostId: String, label: String?, endpointHint: String) {
        events.append(.setHost(hostId, label: label, endpointHint: endpointHint))
    }
    func removeHost(_ hostId: String) { events.append(.removeHost(hostId)) }
    func setStatus(_ hostId: String, _ status: HostStatus) { events.append(.setStatus(hostId, status)) }
    func setServerId(_ hostId: String, _ serverId: String) { events.append(.setServerId(hostId, serverId)) }
    func setHostname(_ hostId: String, _ hostname: String?) { events.append(.setHostname(hostId, hostname)) }
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        events.append(.seedAgents(hostId, ids: agents.map(\.id), truncated: truncated))
    }
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        events.append(.seedWorkspaces(hostId, ids: workspaces.map(\.id), truncated: truncated))
    }
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) { events.append(.agentUpdate(hostId, update)) }
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) { events.append(.workspaceUpdate(hostId, update)) }
}
