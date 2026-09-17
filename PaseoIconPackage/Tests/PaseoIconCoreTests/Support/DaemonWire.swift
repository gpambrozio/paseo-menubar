import Foundation

/// The wire shapes a 0.4.0 daemon sends, as strings, so tests read like transcripts.
enum DaemonWire {
    static func serverInfo(serverId: String, hostname: String? = "studio") -> String {
        let hostnameJSON = hostname.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"\#(serverId)","hostname":\#(hostnameJSON)}}}"#
    }

    static let pong = #"{"type":"pong"}"#

    static func fetchAgentsResponse(requestId: String, agents: [String] = [], hasMore: Bool = false) -> String {
        let entries = agents.map { #"{"agent":\#(agent(id: $0))}"# }.joined(separator: ",")
        return #"{"type":"session","message":{"type":"fetch_agents_response","payload":{"requestId":"\#(requestId)","entries":[\#(entries)],"pageInfo":{"nextCursor":null,"prevCursor":null,"hasMore":\#(hasMore)}}}}"#
    }

    static func fetchWorkspacesResponse(requestId: String, workspaces: [String] = [], hasMore: Bool = false) -> String {
        let entries = workspaces.map { workspace(id: $0) }.joined(separator: ",")
        return #"{"type":"session","message":{"type":"fetch_workspaces_response","payload":{"requestId":"\#(requestId)","entries":[\#(entries)],"pageInfo":{"nextCursor":null,"prevCursor":null,"hasMore":\#(hasMore)}}}}"#
    }

    static func rpcError(requestId: String, error: String) -> String {
        #"{"type":"session","message":{"type":"rpc_error","payload":{"requestId":"\#(requestId)","error":"\#(error)"}}}"#
    }

    static func agent(id: String, workspaceId: String = "ws-1", status: String = "running") -> String {
        #"{"id":"\#(id)","provider":"claude","cwd":"/tmp","workspaceId":"\#(workspaceId)","model":null,"createdAt":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z","lastUserMessageAt":null,"status":"\#(status)","capabilities":{},"currentModeId":null,"availableModes":[],"pendingPermissions":[],"persistence":null,"title":"Agent \#(id)","labels":{}}"#
    }

    static func workspace(id: String, status: String = "running", name: String = "feature") -> String {
        #"{"id":"\#(id)","projectId":"p1","projectDisplayName":"paseo-menubar","projectRootPath":"/tmp/p1","projectKind":"git","workspaceKind":"worktree","name":"\#(name)","status":"\#(status)","archivingAt":null,"activityAt":null,"diffStat":{"additions":3,"deletions":1},"scripts":[],"gitRuntime":{},"githubRuntime":{}}"#
    }

    static func agentUpsert(id: String, status: String = "running") -> String {
        #"{"type":"session","message":{"type":"agent_update","payload":{"kind":"upsert","agent":\#(agent(id: id, status: status))}}}"#
    }

    static func agentRemove(id: String) -> String {
        #"{"type":"session","message":{"type":"agent_update","payload":{"kind":"remove","agentId":"\#(id)"}}}"#
    }

    static func workspaceUpsert(id: String, status: String = "needs_input") -> String {
        #"{"type":"session","message":{"type":"workspace_update","payload":{"kind":"upsert","workspace":\#(workspace(id: id, status: status))}}}"#
    }

    static func workspaceRemove(id: String) -> String {
        #"{"type":"session","message":{"type":"workspace_update","payload":{"kind":"remove","id":"\#(id)"}}}"#
    }
}
