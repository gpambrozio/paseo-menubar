import { getAgentStatusPriority } from "@getpaseo/protocol/agent-state-bucket";
import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
  WorkspaceStateBucket,
} from "@getpaseo/protocol/messages";
import type { HostSnapshot, HostStatus } from "../daemon/host-store.js";

export type TrayIconState = "idle" | "working" | "attention";

/**
 * Section order and labels, copied verbatim from `STATUS_BUCKET_ORDER` and
 * `STATUS_BUCKET_LABELS` in `packages/app/src/hooks/sidebar-status-view-model.ts`
 * in the paseo repo. They live in the app package, not in `@getpaseo/protocol`,
 * so there is nothing to import — re-check that file when the SDK moves.
 *
 * They are copied rather than invented because Paseo's glossary rule is "UI
 * label wins, no synonyms": the tray and the sidebar describe the same
 * workspaces, so they have to use the same words. "Idle" in particular is not a
 * Paseo state at all — a quiet workspace is `done`.
 */
const SECTION_ORDER: readonly WorkspaceStateBucket[] = [
  "needs_input",
  "failed",
  "attention",
  "running",
  "done",
];

export const SECTION_LABELS: Record<WorkspaceStateBucket, string> = {
  needs_input: "Needs input",
  failed: "Failed",
  attention: "Ready to review",
  running: "Working",
  done: "Done",
};

/**
 * The buckets the icon's count is drawn from. `done` is excluded: it is the
 * resting state, so counting it would badge every quiet workspace forever.
 */
const COUNTED_BUCKETS: ReadonlySet<WorkspaceStateBucket> = new Set([
  "needs_input",
  "failed",
  "attention",
]);

/** Rows in a section cap here; the rest become an explicit overflow row. */
const SECTION_ROW_CAP = 15;

export interface TrayWorkspaceRow {
  hostId: string;
  serverId: string | null;
  workspaceId: string;
  /**
   * The agent a click opens, or null when this workspace has none. There is no
   * workspace deep link, so a row without an agent has no in-app target.
   */
  agentId: string | null;
  /** The workspace's resolved display name, the same one the sidebar shows. */
  label: string;
  projectName: string;
  diff: { additions: number; deletions: number } | null;
  /** Null when only one host is configured. */
  hostLabel: string | null;
}

export interface TrayMenuSection {
  bucket: WorkspaceStateBucket;
  rows: TrayWorkspaceRow[];
  /** Rows dropped by the cap. Always rendered, never silent. */
  overflow: number;
}

export interface TrayHostStatus {
  hostId: string;
  label: string;
  status: HostStatus;
}

export interface TrayViewModel {
  icon: TrayIconState;
  count: number;
  sections: TrayMenuSection[];
  hostStatuses: TrayHostStatus[];
  /**
   * Labels of connected hosts with more workspaces than the seed page carried.
   * The rows below them are a subset, not the whole list, and the menu says so.
   */
  truncatedHosts: string[];
  /**
   * Labels of connected hosts whose agent page was capped. The rows are all
   * there, but a click may not find its agent and falls back to the browser.
   */
  agentIndexTruncatedHosts: string[];
  /** Set when config.json cannot be used; the last known-good fleet keeps running. */
  configError: string | null;
}

function isVisible(workspace: WorkspaceDescriptorPayload): boolean {
  return !workspace.archivingAt;
}

/**
 * Groups a host's agents by the workspace they belong to, most relevant first.
 *
 * `getAgentStatusPriority` is the daemon's own urgency ranking (lower is more
 * urgent), so a click lands on the agent Paseo itself would call the reason the
 * workspace is in the bucket it is in. `updatedAt` then `id` break ties, so the
 * same fleet always resolves to the same agent.
 */
function agentsByWorkspace(agents: AgentSnapshotPayload[]): Map<string, AgentSnapshotPayload[]> {
  const grouped = new Map<string, AgentSnapshotPayload[]>();
  for (const agent of agents) {
    if (agent.archivedAt) continue;
    if (!agent.workspaceId) continue;
    const bucket = grouped.get(agent.workspaceId);
    if (bucket) bucket.push(agent);
    else grouped.set(agent.workspaceId, [agent]);
  }
  for (const bucket of grouped.values()) bucket.sort(compareAgentRelevance);
  return grouped;
}

function statusPriority(agent: AgentSnapshotPayload): number {
  return getAgentStatusPriority({
    status: agent.status,
    pendingPermissionCount: agent.pendingPermissions.length,
    requiresAttention: agent.requiresAttention ?? false,
    attentionReason: agent.attentionReason,
  });
}

function compareAgentRelevance(a: AgentSnapshotPayload, b: AgentSnapshotPayload): number {
  const byPriority = statusPriority(a) - statusPriority(b);
  if (byPriority !== 0) return byPriority;
  if (a.updatedAt !== b.updatedAt) return a.updatedAt < b.updatedAt ? 1 : -1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function buildSection(
  bucket: WorkspaceStateBucket,
  rows: TrayWorkspaceRow[],
): TrayMenuSection | null {
  if (rows.length === 0) return null;
  if (rows.length <= SECTION_ROW_CAP) return { bucket, rows, overflow: 0 };
  return { bucket, rows: rows.slice(0, SECTION_ROW_CAP), overflow: rows.length - SECTION_ROW_CAP };
}

export function deriveTrayViewModel(
  hosts: HostSnapshot[],
  options: { configError?: string | null } = {},
): TrayViewModel {
  const showHostLabel = hosts.length > 1;

  // A disconnected host's workspaces are data we cannot vouch for, so they
  // never reach the icon, the count, or the menu.
  const live = hosts.filter((host) => host.status === "connected");

  const rowsByBucket = new Map<WorkspaceStateBucket, TrayWorkspaceRow[]>();
  let running = 0;
  let counted = 0;

  for (const host of live) {
    const agents = agentsByWorkspace(host.agents);
    for (const workspace of host.workspaces) {
      if (!isVisible(workspace)) continue;
      // `status` is the daemon's own bucket. Nothing here recomputes it: the
      // sidebar renders the same field, and a second derivation is a second
      // answer.
      const bucket = workspace.status;
      const row: TrayWorkspaceRow = {
        hostId: host.hostId,
        serverId: host.serverId,
        workspaceId: workspace.id,
        agentId: agents.get(workspace.id)?.[0]?.id ?? null,
        label: workspace.name,
        projectName: workspace.projectDisplayName,
        diff: workspace.diffStat ?? null,
        hostLabel: showHostLabel ? host.label : null,
      };
      const existing = rowsByBucket.get(bucket);
      if (existing) existing.push(row);
      else rowsByBucket.set(bucket, [row]);
      if (COUNTED_BUCKETS.has(bucket)) counted += 1;
      if (bucket === "running") running += 1;
    }
  }

  const sections = SECTION_ORDER.map((bucket) =>
    buildSection(bucket, rowsByBucket.get(bucket) ?? []),
  ).filter((section): section is TrayMenuSection => section !== null);

  const icon: TrayIconState = counted > 0 ? "attention" : running > 0 ? "working" : "idle";

  return {
    icon,
    count: counted,
    sections,
    truncatedHosts: live.filter((host) => host.workspacesTruncated).map((host) => host.label),
    agentIndexTruncatedHosts: live.filter((host) => host.agentsTruncated).map((host) => host.label),
    configError: options.configError ?? null,
    hostStatuses: hosts.map((host) => ({
      hostId: host.hostId,
      label: host.label,
      status: host.status,
    })),
  };
}
