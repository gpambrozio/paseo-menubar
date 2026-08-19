import { afterEach, describe, expect, it } from "vitest";
import { Writable } from "node:stream";
import pino from "pino";
import { hashDaemonPassword } from "@getpaseo/server";
import type { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
} from "@getpaseo/protocol/messages";
import { HostStore } from "./host-store.js";
import { createHostConnection } from "./host-connection.js";
import { startDaemon } from "./daemon-harness.js";

const localEntry = {
  id: "h1",
  label: "local",
  type: "directTcp",
  endpoint: "127.0.0.1:6767",
  useTls: false,
} as const;

function agent(id: string): AgentSnapshotPayload {
  return {
    id,
    provider: "claude",
    cwd: `/work/${id}`,
    model: null,
    createdAt: "2026-08-16T00:00:00.000Z",
    updatedAt: "2026-08-16T00:00:00.000Z",
    lastUserMessageAt: null,
    status: "idle",
    capabilities: {
      supportsStreaming: false,
      supportsSessionPersistence: false,
      supportsDynamicModes: false,
      supportsMcpServers: false,
      supportsReasoningStream: false,
      supportsToolInvocations: false,
    },
    currentModeId: null,
    availableModes: [],
    pendingPermissions: [],
    persistence: null,
    title: id,
    labels: {},
  } as AgentSnapshotPayload;
}

function workspace(id: string): WorkspaceDescriptorPayload {
  return {
    id,
    projectId: "p1",
    projectDisplayName: "paseo",
    projectRootPath: "/work",
    workspaceDirectory: "/work",
    projectKind: "git",
    workspaceKind: "worktree",
    name: id,
    status: "done",
    statusEnteredAt: null,
    activityAt: null,
    archivingAt: null,
    scripts: [],
  } as WorkspaceDescriptorPayload;
}

type ConnectionState = ReturnType<DaemonClient["getConnectionState"]>;

/**
 * Enough of `DaemonClient` for the connection to drive: connection
 * transitions on demand, and a seed that can be made to fail. A real daemon
 * will not reject `fetchAgents` on a healthy socket when asked to.
 */
class FakeClient {
  state: ConnectionState = { status: "idle" };
  seedFailures = 0;
  workspaceSeedFailures = 0;
  hasMore = false;
  workspacesHasMore = false;
  agents: AgentSnapshotPayload[] = [];
  workspaces: WorkspaceDescriptorPayload[] = [];
  readonly fetchOptions: unknown[] = [];
  readonly fetchWorkspaceOptions: unknown[] = [];
  private readonly listeners = new Set<(state: ConnectionState) => void>();

  asClient(): DaemonClient {
    return this as unknown as DaemonClient;
  }

  setState(state: ConnectionState): void {
    this.state = state;
    for (const listener of this.listeners) listener(state);
  }

  getConnectionState(): ConnectionState {
    return this.state;
  }

  subscribeConnectionStatus(listener: (state: ConnectionState) => void): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  private readonly handlers = new Map<string, Set<(message: unknown) => void>>();

  on(type: string, handler: (message: unknown) => void): () => void {
    const existing = this.handlers.get(type) ?? new Set();
    existing.add(handler);
    this.handlers.set(type, existing);
    return () => existing.delete(handler);
  }

  /** Delivers one subscription message, the way the real client's stream does. */
  emit(type: string, payload: unknown): void {
    for (const handler of this.handlers.get(type) ?? []) handler({ type, payload });
  }

  hostname: string | null = null;

  async connect(): Promise<void> {}

  async close(): Promise<void> {}

  getLastServerInfoMessage(): { serverId: string; hostname: string | null } {
    return { serverId: "srv-1", hostname: this.hostname };
  }

  async fetchAgents(options: unknown): Promise<unknown> {
    this.fetchOptions.push(options);
    if (this.seedFailures > 0) {
      this.seedFailures -= 1;
      throw new Error("seed failed");
    }
    return {
      entries: this.agents.map((item) => ({ agent: item, project: null })),
      pageInfo: { nextCursor: null, prevCursor: null, hasMore: this.hasMore },
    };
  }

  async fetchWorkspaces(options: unknown): Promise<unknown> {
    this.fetchWorkspaceOptions.push(options);
    if (this.workspaceSeedFailures > 0) {
      this.workspaceSeedFailures -= 1;
      throw new Error("workspace seed failed");
    }
    return {
      entries: this.workspaces,
      pageInfo: { nextCursor: null, prevCursor: null, hasMore: this.workspacesHasMore },
    };
  }
}

/**
 * A pino destination that counts log lines containing `needle`, so a test can
 * observe how many times the daemon rejected a connection attempt without
 * reaching into daemon internals.
 */
function createLogCounter(needle: string): { logger: pino.Logger; count: () => number } {
  let count = 0;
  const stream = new Writable({
    write(chunk, _encoding, callback) {
      if (chunk.toString().includes(needle)) count += 1;
      callback();
    },
  });
  return { logger: pino({ level: "warn" }, stream), count: () => count };
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("timed out waiting for condition");
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

describe("createHostConnection seeding", () => {
  function connect(client: FakeClient, store: HostStore) {
    const connection = createHostConnection({
      entry: localEntry,
      store,
      createClient: () => client.asClient(),
    });
    cleanups.push(() => connection.close());
    client.setState({ status: "connecting", attempt: 0 });
    client.setState({ status: "connected" });
    return connection;
  }

  it("retries a failed seed instead of pinning a live host at disconnected", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.seedFailures = 1;
    client.agents = [agent("a1")];
    connect(client, store);

    // The socket stays up throughout, so nothing else would ever seed again.
    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.agents.map((item) => item.id)).toEqual(["a1"]);
    expect(client.fetchOptions.length).toBeGreaterThanOrEqual(2);
  });

  it("seeds with the same rule the live subscription applies", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    // `scope: "active"` would narrow harder than the subscription does, so
    // streamed-in agents would disappear at the next re-seed.
    expect(client.fetchOptions[0]).not.toHaveProperty("scope");
    expect(client.fetchOptions[0]).toHaveProperty("subscribe");
  });

  it("asks for the agents that drive the icon first, so the page cap cannot skew the count", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    // Ascending `status_priority` is attention-first: the daemon ranks
    // pending permission 0, error 1, running 2, initializing 3, the rest 4.
    expect(client.fetchOptions[0]).toMatchObject({
      sort: [
        { key: "status_priority", direction: "asc" },
        { key: "updated_at", direction: "desc" },
      ],
    });
  });

  it("seeds workspaces and subscribes to their updates", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.workspaces = [workspace("w1"), workspace("w2")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.workspaces.map((item) => item.id)).toEqual(["w1", "w2"]);
    expect(client.fetchWorkspaceOptions[0]).toMatchObject({
      sort: [{ key: "status_priority", direction: "asc" }],
      page: { limit: 200 },
    });
    // Without `subscribe` the daemon sends no `workspace_update` at all, so
    // the menu would freeze at the seed.
    expect(client.fetchWorkspaceOptions[0]).toHaveProperty("subscribe");
  });

  it("carries the daemon's hostname into the store alongside its serverId", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.hostname = "build-box.local";
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.hostname).toBe("build-box.local");
    expect(store.snapshot()[0]?.serverId).toBe("srv-1");
  });

  it("leaves the hostname null when the daemon does not report one", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    // FakeClient's hostname defaults to null, standing in for a daemon old
    // enough not to send the field at all -- the protocol schema normalizes
    // an absent field to null, same as an explicit one.
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.hostname).toBeNull();
  });

  it("retries when only the workspace seed fails, and applies neither list until both land", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.workspaceSeedFailures = 1;
    client.agents = [agent("a1")];
    client.workspaces = [workspace("w1")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
    // The agent fetch succeeded on the first attempt, but its result is not
    // applied on its own: a half-seeded host pairs one fresh list with a
    // stale one.
    expect(store.snapshot()[0]?.agents).toEqual([]);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.agents.map((item) => item.id)).toEqual(["a1"]);
    expect(store.snapshot()[0]?.workspaces.map((item) => item.id)).toEqual(["w1"]);
  });

  it("applies a streamed workspace upsert", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    client.emit("workspace_update", { kind: "upsert", workspace: workspace("w1") });
    expect(store.snapshot()[0]?.workspaces.map((item) => item.id)).toEqual(["w1"]);
  });

  it("reads a streamed workspace removal from `id`, not `agentId`", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.workspaces = [workspace("w1"), workspace("w2")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    // `workspace_update`'s removal field is `id`; `agent_update`'s is
    // `agentId`. Reading the wrong one yields `undefined` and a row that never
    // leaves the menu.
    client.emit("workspace_update", { kind: "remove", id: "w1" });
    expect(store.snapshot()[0]?.workspaces.map((item) => item.id)).toEqual(["w2"]);
  });

  it("reads a streamed agent removal from `agentId`", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.agents = [agent("a1"), agent("a2")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    client.emit("agent_update", { kind: "remove", agentId: "a1" });
    expect(store.snapshot()[0]?.agents.map((item) => item.id)).toEqual(["a2"]);
  });

  it("carries the workspace page's hasMore through as a visible cap", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.workspacesHasMore = true;
    client.workspaces = [workspace("w1")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.workspacesTruncated).toBe(true);
    expect(store.snapshot()[0]?.agentsTruncated).toBe(false);
  });

  it("carries the agent page's hasMore through as a visible cap", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    client.hasMore = true;
    client.agents = [agent("a1")];
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    expect(store.snapshot()[0]?.agentsTruncated).toBe(true);
    expect(store.snapshot()[0]?.workspacesTruncated).toBe(false);
  });

  it("reports each connection transition, including connecting", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    const seen: string[] = [];
    store.subscribe(() => {
      const status = store.snapshot()[0]?.status;
      if (status && seen[seen.length - 1] !== status) seen.push(status);
    });
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    client.setState({ status: "disconnected", reason: "Transport closed" });
    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
    client.setState({ status: "connecting", attempt: 1 });

    await waitFor(() => store.snapshot()[0]?.status === "connecting");
    expect(seen).toEqual(["connecting", "connected", "disconnected", "connecting"]);
  });

  it("classifies an auth rejection as unauthorized rather than disconnected", async () => {
    const store = new HostStore();
    const client = new FakeClient();
    connect(client, store);

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    client.setState({ status: "disconnected", reason: "Incorrect password" });

    await waitFor(() => store.snapshot()[0]?.status === "unauthorized");
    // Retrying a wrong password behind backoff forever is the failure mode to
    // avoid: later transitions must not move the host off `unauthorized`.
    client.setState({ status: "connecting", attempt: 1 });
    client.setState({ status: "connected" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(store.snapshot()[0]?.status).toBe("unauthorized");
  });
});

describe("createHostConnection", () => {
  it("connects, seeds, and records the daemon's serverId", async () => {
    const harness = await startDaemon();
    cleanups.push(harness.stop);

    const store = new HostStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");

    const host = store.snapshot()[0];
    expect(host?.agents).toEqual([]);
    // A real daemon answers `fetch_workspaces_request` too, which is what puts
    // rows in the menu. An empty home has no workspaces, but reaching
    // `connected` at all means both fetches resolved.
    expect(host?.workspaces).toEqual([]);
    expect(host?.serverId).toBeTruthy();
    // The daemon was started with `hostnames: true`, so a real `server_info`
    // message carries a real machine hostname. Asserting a non-empty string
    // rather than a specific value keeps this from being brittle about
    // whatever this test happens to run on.
    expect(typeof host?.hostname).toBe("string");
    expect(host?.hostname?.length).toBeGreaterThan(0);
  });

  it("reports disconnected when the daemon goes away", async () => {
    const harness = await startDaemon();
    const store = new HostStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    await harness.stop();

    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
  });

  it("reports connecting again while the SDK retries a lost connection", async () => {
    const harness = await startDaemon();
    const store = new HostStore();

    // Record every status the store passes through: a reconnect attempt's
    // `connecting` leg can be shorter than any polling interval, so the
    // assertion has to see transitions, not a sampled value.
    const seen: string[] = [];
    store.subscribe(() => {
      const status = store.snapshot()[0]?.status;
      if (status && seen[seen.length - 1] !== status) seen.push(status);
    });

    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    const afterConnected = seen.length;
    await harness.stop();

    await waitFor(() => seen.slice(afterConnected).includes("connecting"));
    expect(seen).toContain("connected");
    expect(seen.slice(afterConnected)).toContain("disconnected");
  });

  it("marks a wrong password unauthorized and stops retrying", async () => {
    const rightPassword = "correct-horse-battery-staple";
    const { logger, count } = createLogCounter(
      "Rejected WebSocket connection with invalid daemon password",
    );
    const harness = await startDaemon({
      auth: { password: hashDaemonPassword(rightPassword) },
      logger,
    });
    cleanups.push(harness.stop);

    const store = new HostStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
        password: "wrong-password",
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "unauthorized");

    // At least one rejected attempt got us to "unauthorized". Give the
    // client's exponential-backoff reconnect loop (base delay 1.5s) ample
    // room to have fired again if retries were not actually stopped.
    const rejectionsAtUnauthorized = count();
    expect(rejectionsAtUnauthorized).toBeGreaterThanOrEqual(1);

    await new Promise((resolve) => setTimeout(resolve, 4_000));

    expect(count()).toBe(rejectionsAtUnauthorized);
    expect(store.snapshot()[0]?.status).toBe("unauthorized");
  });
});
