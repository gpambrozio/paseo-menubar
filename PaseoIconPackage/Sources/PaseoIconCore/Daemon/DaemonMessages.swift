import Foundation

// The slice of `@getpaseo/protocol` 0.4.0 `messages.ts` this app speaks.
// Decoding is lenient by design: unknown fields are ignored and enum-like
// strings are kept as strings, because the protocol contract is additive and
// a new daemon must not make the tray fail to parse.

public struct ServerInfo: Equatable, Sendable {
    public let serverId: String
    /// Non-string values become nil, as upstream's `ServerInfoHostnameSchema` does.
    public let hostname: String?

    public init(serverId: String, hostname: String?) {
        self.serverId = serverId
        self.hostname = hostname
    }
}

/// `WorkspaceStateBucketSchema` upstream. The daemon computes the bucket; the
/// tray renders it and never derives it.
public enum WorkspaceStateBucket: String, Codable, CaseIterable, Sendable {
    case needsInput = "needs_input"
    case failed
    case running
    case attention
    case done
}

public struct DiffStat: Codable, Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
}

/// One pending permission request. Only the count matters here: it is the
/// first term of the daemon's own urgency ranking.
public struct AgentPermissionRequest: Codable, Equatable, Sendable {
    public let id: String?
}

public struct WorkspaceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let projectDisplayName: String
    public let name: String
    /// The raw bucket string. `bucket` is nil for a value this build does not know.
    public let status: String
    public let archivingAt: String?
    public let activityAt: String?
    public let diffStat: DiffStat?

    public var bucket: WorkspaceStateBucket? { WorkspaceStateBucket(rawValue: status) }

    public init(
        id: String,
        projectId: String = "p1",
        projectDisplayName: String = "paseo",
        name: String,
        status: String,
        archivingAt: String? = nil,
        activityAt: String? = nil,
        diffStat: DiffStat? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.projectDisplayName = projectDisplayName
        self.name = name
        self.status = status
        self.archivingAt = archivingAt
        self.activityAt = activityAt
        self.diffStat = diffStat
    }
}

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let workspaceId: String?
    public let status: String
    public let title: String?
    public let updatedAt: String
    public let requiresAttention: Bool?
    public let attentionReason: String?
    public let archivedAt: String?
    public let pendingPermissions: [AgentPermissionRequest]?

    public init(
        id: String,
        workspaceId: String? = nil,
        status: String,
        title: String? = nil,
        updatedAt: String,
        requiresAttention: Bool? = nil,
        attentionReason: String? = nil,
        archivedAt: String? = nil,
        pendingPermissions: [AgentPermissionRequest]? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.status = status
        self.title = title
        self.updatedAt = updatedAt
        self.requiresAttention = requiresAttention
        self.attentionReason = attentionReason
        self.archivedAt = archivedAt
        self.pendingPermissions = pendingPermissions
    }

    /// The daemon's own urgency ranking, lower being more urgent, copied from
    /// `getAgentStatusPriority` in `@getpaseo/protocol`'s `agent-state-bucket`.
    /// Ranks pending permission 0, error 1, running 2, initializing 3, and
    /// everything else 4.
    public var statusPriority: Int {
        if (pendingPermissions?.count ?? 0) > 0 || attentionReason == "permission" { return 0 }
        if status == "error" || attentionReason == "error" { return 1 }
        if status == "running" { return 2 }
        if status == "initializing" { return 3 }
        return 4
    }
}

public enum AgentUpdate: Equatable, Sendable {
    case upsert(AgentSnapshot)
    case remove(agentId: String)
}

public enum WorkspaceUpdate: Equatable, Sendable {
    case upsert(WorkspaceDescriptor)
    case remove(id: String)
}

public struct PageInfo: Codable, Equatable, Sendable {
    public let hasMore: Bool
}

public struct FetchAgentsResponsePayload: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let agent: AgentSnapshot
    }

    public let requestId: String
    public let entries: [Entry]
    public let pageInfo: PageInfo
}

public struct FetchWorkspacesResponsePayload: Decodable, Equatable, Sendable {
    public let requestId: String
    public let entries: [WorkspaceDescriptor]
    public let pageInfo: PageInfo
}

public struct SortKey: Encodable, Equatable, Sendable {
    public let key: String
    public let direction: String

    public init(key: String, direction: String) {
        self.key = key
        self.direction = direction
    }
}

public struct FetchAgentsOptions: Equatable, Sendable {
    public var sort: [SortKey]
    public var pageLimit: Int
    public var subscribe: Bool

    public init(sort: [SortKey], pageLimit: Int, subscribe: Bool) {
        self.sort = sort
        self.pageLimit = pageLimit
        self.subscribe = subscribe
    }
}

public typealias FetchWorkspacesOptions = FetchAgentsOptions

// MARK: - Wire encoding

struct EmptyObject: Encodable {}

struct SessionEnvelope<Message: Encodable>: Encodable {
    let type = "session"
    let message: Message
}

struct HelloMessage: Encodable {
    let type = "hello"
    let clientId: String
    let clientType: String
    let protocolVersion: Int
    let appVersion: String
    let capabilities: [String: Bool]
}

struct FetchRequestMessage: Encodable {
    struct Page: Encodable { let limit: Int }
    let type: String
    let requestId: String
    let sort: [SortKey]
    let page: Page
    let subscribe: EmptyObject?
}

// MARK: - Wire decoding

enum InboundMessage: Equatable {
    case pong
    case serverInfo(ServerInfo)
    case agentUpdate(AgentUpdate)
    case workspaceUpdate(WorkspaceUpdate)
    /// A `*_response` session message; `payload` is its payload re-serialized for typed decoding.
    case response(requestId: String, type: String, payload: Data)
    case rpcError(requestId: String, error: String)
    case other(type: String)
}

enum InboundParseError: Error, Equatable {
    case notAnObject
    case missingType
    case malformed(String)
}

enum InboundParser {
    static func parse(_ text: String) throws -> InboundMessage {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw InboundParseError.notAnObject
        }
        guard let envelopeType = root["type"] as? String else { throw InboundParseError.missingType }
        if envelopeType == "pong" { return .pong }
        guard envelopeType == "session", let message = root["message"] as? [String: Any] else {
            return .other(type: envelopeType)
        }
        guard let type = message["type"] as? String else { throw InboundParseError.missingType }
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch type {
        case "status":
            guard payload["status"] as? String == "server_info" else { return .other(type: "status") }
            guard let serverId = (payload["serverId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !serverId.isEmpty else {
                throw InboundParseError.malformed("server_info without serverId")
            }
            return .serverInfo(ServerInfo(serverId: serverId, hostname: payload["hostname"] as? String))
        case "agent_update":
            switch payload["kind"] as? String {
            case "upsert":
                guard let agent = payload["agent"] else { throw InboundParseError.malformed("agent upsert without agent") }
                return .agentUpdate(.upsert(try decode(AgentSnapshot.self, from: agent)))
            case "remove":
                guard let agentId = payload["agentId"] as? String else {
                    throw InboundParseError.malformed("agent remove without agentId")
                }
                return .agentUpdate(.remove(agentId: agentId))
            default:
                throw InboundParseError.malformed("agent_update kind")
            }
        case "workspace_update":
            switch payload["kind"] as? String {
            case "upsert":
                guard let workspace = payload["workspace"] else {
                    throw InboundParseError.malformed("workspace upsert without workspace")
                }
                return .workspaceUpdate(.upsert(try decode(WorkspaceDescriptor.self, from: workspace)))
            case "remove":
                // The removal field here is `id`; `agent_update`'s is `agentId`.
                guard let id = payload["id"] as? String else {
                    throw InboundParseError.malformed("workspace remove without id")
                }
                return .workspaceUpdate(.remove(id: id))
            default:
                throw InboundParseError.malformed("workspace_update kind")
            }
        case "rpc_error":
            guard let requestId = payload["requestId"] as? String else { return .other(type: type) }
            return .rpcError(requestId: requestId, error: payload["error"] as? String ?? "rpc_error")
        default:
            if type.hasSuffix("_response"), let requestId = payload["requestId"] as? String {
                let data = try JSONSerialization.data(withJSONObject: payload)
                return .response(requestId: requestId, type: type, payload: data)
            }
            return .other(type: type)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
