import Foundation

/// The tray icon is always one bucket's icon: the highest-priority non-empty
/// one, or `done` (the Paseo mark) when there are no workspaces at all.
public typealias TrayIconState = WorkspaceStateBucket

public struct TrayWorkspaceRow: Equatable, Sendable, Identifiable {
    public let hostId: String
    public let serverId: String?
    public let workspaceId: String
    /// The agent a click opens, or nil when this workspace has none. There is
    /// no workspace deep link, so a row without an agent has no in-app target.
    public let agentId: String?
    /// The workspace's resolved display name, the same one the sidebar shows.
    public let label: String
    public let projectName: String
    /// Nil when only one host is configured.
    public let hostLabel: String?

    public var id: String { "\(hostId)/\(workspaceId)" }
}

public struct TrayMenuSection: Equatable, Sendable, Identifiable {
    public let bucket: WorkspaceStateBucket
    public let rows: [TrayWorkspaceRow]
    /// Rows dropped by the cap. Always rendered, never silent.
    public let overflow: Int

    public var id: String { bucket.rawValue }
}

public struct TrayHostStatus: Equatable, Sendable, Identifiable {
    public let hostId: String
    public let label: String
    public let status: HostStatus

    public var id: String { hostId }
}

public struct TrayViewModel: Equatable, Sendable {
    public let icon: TrayIconState
    public let count: Int
    public let sections: [TrayMenuSection]
    public let hostStatuses: [TrayHostStatus]
    /// Labels of connected hosts with more workspaces than the seed page
    /// carried. The rows below them are a subset, and the menu says so.
    public let truncatedHosts: [String]
    /// Labels of connected hosts whose agent page was capped. The rows are all
    /// there, but a click may not find its agent and falls back to the browser.
    public let agentIndexTruncatedHosts: [String]
    /// Set when the registry cannot be used; the last known-good fleet keeps running.
    public let configError: String?
    /// Workspaces whose `status` this build does not recognise, counted by the
    /// string the daemon sent. A newer daemon can add a bucket, and the spec is
    /// explicit that one this build does not know "renders as an unknown row,
    /// never a crash and never a guess" — dropping them would make a fleet of
    /// live workspaces read as an empty one. Nothing here decides which bucket
    /// they belong in; that decision lives in the daemon.
    public let unknownStates: [String: Int]

    init(
        icon: TrayIconState,
        count: Int,
        sections: [TrayMenuSection],
        hostStatuses: [TrayHostStatus],
        truncatedHosts: [String],
        agentIndexTruncatedHosts: [String],
        configError: String?,
        unknownStates: [String: Int] = [:]
    ) {
        self.icon = icon
        self.count = count
        self.sections = sections
        self.hostStatuses = hostStatuses
        self.truncatedHosts = truncatedHosts
        self.agentIndexTruncatedHosts = agentIndexTruncatedHosts
        self.configError = configError
        self.unknownStates = unknownStates
    }

    public static let empty = TrayViewModel(
        icon: .done, count: 0, sections: [], hostStatuses: [],
        truncatedHosts: [], agentIndexTruncatedHosts: [], configError: nil
    )
}

public enum TrayViewModelBuilder {
    /// Section order and labels, copied verbatim from `STATUS_BUCKET_ORDER`
    /// and `STATUS_BUCKET_LABELS` in the Paseo app's
    /// `sidebar-status-view-model.ts`. They are copied rather than invented
    /// because Paseo's glossary rule is "UI label wins, no synonyms": the tray
    /// and the sidebar describe the same workspaces. "Idle" in particular is
    /// not a Paseo state at all; a quiet workspace is `done`.
    public static let sectionOrder: [WorkspaceStateBucket] = [.needsInput, .failed, .attention, .running, .done]

    public static let sectionLabels: [WorkspaceStateBucket: String] = [
        .needsInput: "Needs input",
        .failed: "Failed",
        .attention: "Ready to review",
        .running: "Working",
        .done: "Done",
    ]

    /// The asset name for each bucket's icon.
    public static let iconNames: [WorkspaceStateBucket: String] = [
        .needsInput: "needsInput",
        .failed: "failed",
        .attention: "attention",
        .running: "running",
        .done: "done",
    ]

    /// The buckets the icon's count is drawn from. `done` is excluded: it is
    /// the resting state, so counting it would badge every quiet workspace.
    static let countedBuckets: Set<WorkspaceStateBucket> = [.needsInput, .failed, .attention]

    /// Rows in a section cap here; the rest become an explicit overflow row.
    static let sectionRowCap = 15

    public static func build(hosts: [HostSnapshot], configError: String? = nil) -> TrayViewModel {
        let showHostLabel = hosts.count > 1
        // A disconnected host's workspaces are data we cannot vouch for, so
        // they never reach the icon, the count, or the menu.
        let live = hosts.filter { $0.status == .connected }

        var rowsByBucket: [WorkspaceStateBucket: [TrayWorkspaceRow]] = [:]
        var unknownStates: [String: Int] = [:]
        var counted = 0

        for host in live {
            let agents = agentsByWorkspace(host.agents)
            let hostName = resolveHostName(host)
            for workspace in host.workspaces {
                guard workspace.archivingAt == nil else { continue }
                // `status` is the daemon's own bucket. Nothing here recomputes
                // it: the sidebar renders the same field, and a second
                // derivation is a second answer. A bucket this build does not
                // know is dropped rather than guessed at.
                guard let bucket = workspace.bucket else {
                    // A bucket this build does not know. Counted so the menu
                    // can say so, because a silent drop turns a busy fleet into
                    // an apparently empty one, and never sorted into a bucket
                    // here — that would be the guess the rule forbids.
                    unknownStates[workspace.status, default: 0] += 1
                    continue
                }
                let row = TrayWorkspaceRow(
                    hostId: host.hostId,
                    serverId: host.serverId,
                    workspaceId: workspace.id,
                    agentId: agents[workspace.id]?.first?.id,
                    label: workspace.name,
                    projectName: workspace.projectDisplayName,
                    hostLabel: showHostLabel ? hostName : nil
                )
                rowsByBucket[bucket, default: []].append(row)
                if countedBuckets.contains(bucket) { counted += 1 }
            }
        }

        let sections = sectionOrder.compactMap { bucket -> TrayMenuSection? in
            guard let rows = rowsByBucket[bucket], !rows.isEmpty else { return nil }
            if rows.count <= sectionRowCap { return TrayMenuSection(bucket: bucket, rows: rows, overflow: 0) }
            return TrayMenuSection(bucket: bucket, rows: Array(rows.prefix(sectionRowCap)), overflow: rows.count - sectionRowCap)
        }

        return TrayViewModel(
            // `sections` is already in sectionOrder and holds only non-empty
            // buckets, so its first entry is the highest-priority one. No
            // workspaces at all falls back to `done`, the resting state.
            icon: sections.first?.bucket ?? .done,
            count: counted,
            sections: sections,
            hostStatuses: hosts.map { TrayHostStatus(hostId: $0.hostId, label: resolveHostName($0), status: $0.status) },
            truncatedHosts: live.filter(\.workspacesTruncated).map(resolveHostName),
            agentIndexTruncatedHosts: live.filter(\.agentsTruncated).map(resolveHostName),
            configError: configError,
            // Left out of `icon` and `count` on purpose: whether an unknown
            // state needs attention is exactly what this build cannot know.
            unknownStates: unknownStates
        )
    }

    /// Groups a host's agents by workspace, most relevant first, so a click
    /// lands on the agent Paseo itself would call the reason the workspace is
    /// in the bucket it is in. `updatedAt` then `id` break ties, so the same
    /// fleet always resolves to the same agent.
    private static func agentsByWorkspace(_ agents: [AgentSnapshot]) -> [String: [AgentSnapshot]] {
        var grouped: [String: [AgentSnapshot]] = [:]
        for agent in agents {
            guard agent.archivedAt == nil, let workspaceId = agent.workspaceId else { continue }
            grouped[workspaceId, default: []].append(agent)
        }
        for (workspaceId, bucket) in grouped {
            grouped[workspaceId] = bucket.sorted(by: isMoreRelevant)
        }
        return grouped
    }

    private static func isMoreRelevant(_ a: AgentSnapshot, _ b: AgentSnapshot) -> Bool {
        if a.statusPriority != b.statusPriority { return a.statusPriority < b.statusPriority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }
}

/// The display name for a host: the user's explicit label if they set one,
/// else the daemon's own hostname, else its serverId, else the entry's own
/// connection endpoint as a last resort. Matches Paseo's own precedence for
/// the same decision, so a host paired here reads the way it would in Paseo.
public func resolveHostName(_ host: HostSnapshot) -> String {
    resolveHostName(label: host.label, hostname: host.hostname, serverId: host.serverId, endpointHint: host.endpointHint)
}

public func resolveHostName(label: String?, hostname: String?, serverId: String?, endpointHint: String) -> String {
    label ?? shortenHostname(hostname) ?? serverId ?? endpointHint
}

/// mDNS and default-domain suffixes, longest first so `.localdomain` wins.
private let hostnameSuffixes = [".localdomain", ".local"]

/// Drops the trailing `.local` / `.localdomain` a machine reports over mDNS:
/// `build-box.local` is the same machine as `build-box`, and the suffix is an
/// artifact of how the name is announced. Only the daemon-reported hostname
/// goes through here; an explicit label is rendered verbatim, because a user
/// who types `foo.local` means it. Returns nil when stripping would leave
/// nothing, so a host named exactly `.local` falls through to the next tier.
func shortenHostname(_ hostname: String?) -> String? {
    guard let hostname else { return nil }
    // A fully-qualified name may carry the DNS root dot; it is not part of the label.
    let trimmed = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
    let lowered = trimmed.lowercased()
    for suffix in hostnameSuffixes where lowered.hasSuffix(suffix) {
        let shortened = String(trimmed.dropLast(suffix.count))
        return shortened.isEmpty ? nil : shortened
    }
    return trimmed.isEmpty ? nil : trimmed
}
