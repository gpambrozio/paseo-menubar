import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
} from "@getpaseo/protocol/messages";

export type HostStatus =
  | "connecting"
  | "connected"
  | "disconnected"
  | "unauthorized"
  /** The entry itself is unusable — e.g. an endpoint that cannot form a URL. */
  | "invalid";

/** The `agent_update` payload shape, narrowed to what the store applies. */
export type AgentUpdate =
  | { kind: "upsert"; agent: AgentSnapshotPayload }
  | { kind: "remove"; agentId: string };

/** The `workspace_update` payload shape, narrowed to what the store applies. */
export type WorkspaceUpdate =
  | { kind: "upsert"; workspace: WorkspaceDescriptorPayload }
  | { kind: "remove"; workspaceId: string };

/**
 * One host's replicated state.
 *
 * Two lists, because they answer two different questions. `workspaces` is what
 * the menu shows — the same unit and the same daemon-computed status bucket the
 * Paseo sidebar renders. `agents` exists only to resolve a click: there is no
 * workspace deep link, so opening a row means opening one of its agents.
 */
export interface HostSnapshot {
  hostId: string;
  label: string;
  status: HostStatus;
  serverId: string | null;
  workspaces: WorkspaceDescriptorPayload[];
  agents: AgentSnapshotPayload[];
  /** The host has more workspaces than the seed page could carry. */
  workspacesTruncated: boolean;
  /** The host has more agents than the seed page could carry. */
  agentsTruncated: boolean;
}

interface HostEntryState {
  label: string;
  status: HostStatus;
  serverId: string | null;
  workspaces: Map<string, WorkspaceDescriptorPayload>;
  agents: Map<string, AgentSnapshotPayload>;
  workspacesTruncated: boolean;
  agentsTruncated: boolean;
}

/** Replicated workspace and agent state, keyed by host. */
export class HostStore {
  private readonly hosts = new Map<string, HostEntryState>();
  private readonly listeners = new Set<() => void>();
  private configError: string | null = null;

  /**
   * A configuration problem the user has to fix. It rides in the store so the
   * menu can show it: a modal error box steals focus from the editor the user
   * is fixing the file in, and on its own leaves the tray showing an
   * unexplained "No workspaces".
   */
  setConfigError(message: string | null): void {
    if (this.configError === message) return;
    this.configError = message;
    this.emit();
  }

  getConfigError(): string | null {
    return this.configError;
  }

  setHost(hostId: string, label: string): void {
    const existing = this.hosts.get(hostId);
    if (existing) {
      existing.label = label;
    } else {
      this.hosts.set(hostId, {
        label,
        status: "connecting",
        serverId: null,
        workspaces: new Map(),
        agents: new Map(),
        workspacesTruncated: false,
        agentsTruncated: false,
      });
    }
    this.emit();
  }

  removeHost(hostId: string): void {
    if (this.hosts.delete(hostId)) this.emit();
  }

  setStatus(hostId: string, status: HostStatus): void {
    const host = this.hosts.get(hostId);
    if (!host || host.status === status) return;
    host.status = status;
    this.emit();
  }

  setServerId(hostId: string, serverId: string): void {
    const host = this.hosts.get(hostId);
    if (!host || host.serverId === serverId) return;
    host.serverId = serverId;
    this.emit();
  }

  /** Replaces the host's agents wholesale. Called on connect and on every reconnect. */
  seedAgents(
    hostId: string,
    agents: AgentSnapshotPayload[],
    options: { truncated?: boolean } = {},
  ): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    host.agents = new Map(agents.map((entry) => [entry.id, entry]));
    host.agentsTruncated = options.truncated === true;
    this.emit();
  }

  /** Replaces the host's workspaces wholesale. Same rule as `seedAgents`. */
  seedWorkspaces(
    hostId: string,
    workspaces: WorkspaceDescriptorPayload[],
    options: { truncated?: boolean } = {},
  ): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    host.workspaces = new Map(workspaces.map((entry) => [entry.id, entry]));
    host.workspacesTruncated = options.truncated === true;
    this.emit();
  }

  applyAgentUpdate(hostId: string, update: AgentUpdate): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    if (update.kind === "upsert") {
      host.agents.set(update.agent.id, update.agent);
    } else {
      if (!host.agents.delete(update.agentId)) return;
    }
    this.emit();
  }

  applyWorkspaceUpdate(hostId: string, update: WorkspaceUpdate): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    if (update.kind === "upsert") {
      host.workspaces.set(update.workspace.id, update.workspace);
    } else {
      if (!host.workspaces.delete(update.workspaceId)) return;
    }
    this.emit();
  }

  snapshot(): HostSnapshot[] {
    return [...this.hosts.entries()].map(([hostId, host]) => ({
      hostId,
      label: host.label,
      status: host.status,
      serverId: host.serverId,
      workspaces: [...host.workspaces.values()],
      agents: [...host.agents.values()],
      workspacesTruncated: host.workspacesTruncated,
      agentsTruncated: host.agentsTruncated,
    }));
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}
