import Foundation
@testable import PaseoIconCore

/// Builders for the shapes the store and view model work in.
enum Fixture {
    static func agent(
        _ id: String,
        workspaceId: String? = "w1",
        status: String = "idle",
        updatedAt: String = "2026-08-16T00:00:00.000Z",
        requiresAttention: Bool? = nil,
        attentionReason: String? = nil,
        archivedAt: String? = nil,
        pendingPermissions: Int = 0
    ) -> AgentSnapshot {
        AgentSnapshot(
            id: id,
            workspaceId: workspaceId,
            status: status,
            title: id,
            updatedAt: updatedAt,
            requiresAttention: requiresAttention,
            attentionReason: attentionReason,
            archivedAt: archivedAt,
            pendingPermissions: (0..<pendingPermissions).map { AgentPermissionRequest(id: "p\($0)") }
        )
    }

    static func workspace(
        _ id: String,
        name: String? = nil,
        projectDisplayName: String = "paseo",
        status: String = "done",
        archivingAt: String? = nil
    ) -> WorkspaceDescriptor {
        WorkspaceDescriptor(
            id: id,
            projectDisplayName: projectDisplayName,
            name: name ?? id,
            status: status,
            archivingAt: archivingAt
        )
    }

    static func host(
        _ workspaces: [WorkspaceDescriptor] = [],
        hostId: String = "h1",
        label: String? = "laptop",
        hostname: String? = nil,
        endpointHint: String = "127.0.0.1:6767",
        status: HostStatus = .connected,
        serverId: String? = "srv-1",
        agents: [AgentSnapshot] = [],
        workspacesTruncated: Bool = false,
        agentsTruncated: Bool = false
    ) -> HostSnapshot {
        HostSnapshot(
            hostId: hostId,
            label: label,
            hostname: hostname,
            endpointHint: endpointHint,
            status: status,
            serverId: serverId,
            workspaces: workspaces,
            agents: agents,
            workspacesTruncated: workspacesTruncated,
            agentsTruncated: agentsTruncated
        )
    }

    static func directEntry(
        _ id: String,
        label: String? = nil,
        endpoint: String = "127.0.0.1:6767",
        useTls: Bool = false
    ) -> HostEntry {
        .directTcp(id: id, label: label ?? id, endpoint: endpoint, useTls: useTls, password: nil)
    }

    static let relayEntry: HostEntry = .relay(
        id: "r1",
        label: "studio",
        offer: ConnectionOffer(serverId: "srv-2", daemonPublicKeyB64: "AAAA", relay: .init(endpoint: "relay.paseo.sh:443", useTls: true))
    )

    static func config(_ hosts: HostEntry...) throws -> AppConfig {
        try AppConfig.validate(hosts: hosts)
    }
}
