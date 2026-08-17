import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";

export type HostStatus = "connecting" | "connected" | "disconnected" | "unauthorized";

/** The `agent_update` payload shape, narrowed to what the store applies. */
export type AgentUpdate =
  | { kind: "upsert"; agent: AgentSnapshotPayload }
  | { kind: "remove"; agentId: string };

export interface HostAgents {
  hostId: string;
  label: string;
  status: HostStatus;
  serverId: string | null;
  agents: AgentSnapshotPayload[];
  /** The host has more agents than the seed page could carry. */
  truncated: boolean;
}

interface HostEntryState {
  label: string;
  status: HostStatus;
  serverId: string | null;
  agents: Map<string, AgentSnapshotPayload>;
  truncated: boolean;
}

export class AgentStore {
  private readonly hosts = new Map<string, HostEntryState>();
  private readonly listeners = new Set<() => void>();

  setHost(hostId: string, label: string): void {
    const existing = this.hosts.get(hostId);
    if (existing) {
      existing.label = label;
    } else {
      this.hosts.set(hostId, {
        label,
        status: "connecting",
        serverId: null,
        agents: new Map(),
        truncated: false,
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
  seed(
    hostId: string,
    agents: AgentSnapshotPayload[],
    options: { truncated?: boolean } = {},
  ): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    host.agents = new Map(agents.map((entry) => [entry.id, entry]));
    host.truncated = options.truncated === true;
    this.emit();
  }

  applyUpdate(hostId: string, update: AgentUpdate): void {
    const host = this.hosts.get(hostId);
    if (!host) return;
    if (update.kind === "upsert") {
      host.agents.set(update.agent.id, update.agent);
    } else {
      if (!host.agents.delete(update.agentId)) return;
    }
    this.emit();
  }

  snapshot(): HostAgents[] {
    return [...this.hosts.entries()].map(([hostId, host]) => ({
      hostId,
      label: host.label,
      status: host.status,
      serverId: host.serverId,
      agents: [...host.agents.values()],
      truncated: host.truncated,
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
