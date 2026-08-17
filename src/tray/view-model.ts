import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import type { HostAgents, HostStatus } from "../daemon/agent-store.js";

export type TrayIconState = "idle" | "working" | "attention";
export type TraySectionKind = "attention" | "working" | "idle";

/** Rows in the attention section cap here; the rest become an explicit overflow row. */
const ATTENTION_ROW_CAP = 15;

export interface TrayAgentRow {
  hostId: string;
  serverId: string | null;
  agentId: string;
  label: string;
  /** `finished`, `permission`, or `error`; null outside the attention section. */
  detail: string | null;
  /** Null when only one host is configured. */
  hostLabel: string | null;
}

export interface TrayMenuSection {
  kind: TraySectionKind;
  rows: TrayAgentRow[];
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
   * Labels of connected hosts with more agents than the seed page carried.
   * The count below them is a floor, not a total, and the menu says so.
   */
  truncatedHosts: string[];
}

function isVisible(agent: AgentSnapshotPayload): boolean {
  return !agent.archivedAt;
}

function needsAttention(agent: AgentSnapshotPayload): boolean {
  return agent.requiresAttention === true;
}

function isWorking(agent: AgentSnapshotPayload): boolean {
  return agent.status === "running" || agent.status === "initializing";
}

function rowLabel(agent: AgentSnapshotPayload): string {
  const title = agent.title?.trim();
  if (title) return title;
  const segments = agent.cwd.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? agent.cwd;
}

function buildSection(
  kind: TraySectionKind,
  rows: TrayAgentRow[],
  cap: number | null,
): TrayMenuSection | null {
  if (rows.length === 0) return null;
  if (cap === null || rows.length <= cap) return { kind, rows, overflow: 0 };
  return { kind, rows: rows.slice(0, cap), overflow: rows.length - cap };
}

export function deriveTrayViewModel(hosts: HostAgents[]): TrayViewModel {
  const showHostLabel = hosts.length > 1;

  // A disconnected host's agents are data we cannot vouch for, so they never
  // reach the icon, the count, or the menu.
  const live = hosts.filter((host) => host.status === "connected");

  const attention: TrayAgentRow[] = [];
  const working: TrayAgentRow[] = [];
  const idle: TrayAgentRow[] = [];

  for (const host of live) {
    for (const agent of host.agents) {
      if (!isVisible(agent)) continue;
      const base = {
        hostId: host.hostId,
        serverId: host.serverId,
        agentId: agent.id,
        label: rowLabel(agent),
        hostLabel: showHostLabel ? host.label : null,
      };
      if (needsAttention(agent)) {
        attention.push({ ...base, detail: agent.attentionReason ?? null });
      } else if (isWorking(agent)) {
        working.push({ ...base, detail: null });
      } else {
        idle.push({ ...base, detail: null });
      }
    }
  }

  const sections = [
    buildSection("attention", attention, ATTENTION_ROW_CAP),
    buildSection("working", working, null),
    buildSection("idle", idle, null),
  ].filter((section): section is TrayMenuSection => section !== null);

  const icon: TrayIconState =
    attention.length > 0 ? "attention" : working.length > 0 ? "working" : "idle";

  return {
    icon,
    count: attention.length,
    sections,
    truncatedHosts: live.filter((host) => host.truncated).map((host) => host.label),
    hostStatuses: hosts.map((host) => ({
      hostId: host.hostId,
      label: host.label,
      status: host.status,
    })),
  };
}
