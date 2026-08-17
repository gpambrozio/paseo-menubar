import { describe, expect, it, vi } from "vitest";
import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
} from "@getpaseo/protocol/messages";
import { HostStore } from "./host-store.js";

function agent(id: string, overrides: Partial<AgentSnapshotPayload> = {}): AgentSnapshotPayload {
  return {
    id,
    provider: "claude",
    cwd: `/work/${id}`,
    model: null,
    createdAt: "2026-08-16T00:00:00.000Z",
    updatedAt: "2026-08-16T00:00:00.000Z",
    lastUserMessageAt: null,
    status: "idle",
    capabilities: {},
    currentModeId: null,
    availableModes: [],
    pendingPermissions: [],
    persistence: null,
    title: id,
    labels: {},
    ...overrides,
  } as AgentSnapshotPayload;
}

function workspace(
  id: string,
  overrides: Partial<WorkspaceDescriptorPayload> = {},
): WorkspaceDescriptorPayload {
  return {
    id,
    projectId: "p1",
    projectDisplayName: "paseo",
    projectRootPath: "/work",
    projectKind: "git",
    workspaceKind: "worktree",
    name: id,
    status: "done",
    statusEnteredAt: null,
    activityAt: null,
    archivingAt: null,
    scripts: [],
    ...overrides,
  } as WorkspaceDescriptorPayload;
}

describe("HostStore", () => {
  it("seeds a host and reports its workspaces and agents", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedAgents("h1", [agent("a"), agent("b")]);
    store.seedWorkspaces("h1", [workspace("w1")]);

    const [host] = store.snapshot();
    expect(host?.label).toBe("laptop");
    expect(host?.agents.map((a) => a.id)).toEqual(["a", "b"]);
    expect(host?.workspaces.map((w) => w.id)).toEqual(["w1"]);
  });

  it("applies an agent upsert as a full replacement", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedAgents("h1", [agent("a", { status: "idle" })]);
    store.applyAgentUpdate("h1", { kind: "upsert", agent: agent("a", { status: "running" }) });

    expect(store.snapshot()[0]?.agents[0]?.status).toBe("running");
  });

  it("applies a workspace upsert as a full replacement", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedWorkspaces("h1", [workspace("w1", { status: "done" })]);
    store.applyWorkspaceUpdate("h1", {
      kind: "upsert",
      workspace: workspace("w1", { status: "needs_input" }),
    });

    expect(store.snapshot()[0]?.workspaces[0]?.status).toBe("needs_input");
  });

  it("applies an agent remove", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedAgents("h1", [agent("a"), agent("b")]);
    store.applyAgentUpdate("h1", { kind: "remove", agentId: "a" });

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("applies a workspace remove", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedWorkspaces("h1", [workspace("w1"), workspace("w2")]);
    store.applyWorkspaceUpdate("h1", { kind: "remove", workspaceId: "w1" });

    expect(store.snapshot()[0]?.workspaces.map((w) => w.id)).toEqual(["w2"]);
  });

  it("re-seeding replaces wholesale so a subscription gap cannot strand an agent", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedAgents("h1", [agent("a"), agent("b")]);
    store.seedAgents("h1", [agent("b")]);

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("re-seeding replaces workspaces wholesale too", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.seedWorkspaces("h1", [workspace("w1"), workspace("w2")]);
    store.seedWorkspaces("h1", [workspace("w2")]);

    expect(store.snapshot()[0]?.workspaces.map((w) => w.id)).toEqual(["w2"]);
  });

  it("tracks status and serverId per host", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    expect(store.snapshot()[0]?.status).toBe("connecting");

    store.setStatus("h1", "connected");
    store.setServerId("h1", "srv-1");

    expect(store.snapshot()[0]?.status).toBe("connected");
    expect(store.snapshot()[0]?.serverId).toBe("srv-1");
  });

  it("carries each seed's truncation flag independently and clears it on a complete re-seed", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    expect(store.snapshot()[0]?.workspacesTruncated).toBe(false);
    expect(store.snapshot()[0]?.agentsTruncated).toBe(false);

    store.seedWorkspaces("h1", [workspace("w1")], { truncated: true });
    store.seedAgents("h1", [agent("a")]);
    expect(store.snapshot()[0]?.workspacesTruncated).toBe(true);
    expect(store.snapshot()[0]?.agentsTruncated).toBe(false);

    store.seedAgents("h1", [agent("a")], { truncated: true });
    expect(store.snapshot()[0]?.agentsTruncated).toBe(true);

    store.seedWorkspaces("h1", [workspace("w1")]);
    expect(store.snapshot()[0]?.workspacesTruncated).toBe(false);
  });

  it("removing a host drops it entirely", () => {
    const store = new HostStore();
    store.setHost("h1", "laptop");
    store.removeHost("h1");
    expect(store.snapshot()).toEqual([]);
  });

  it("holds a configuration error and notifies only when it changes", () => {
    const store = new HostStore();
    const listener = vi.fn();
    store.subscribe(listener);

    expect(store.getConfigError()).toBeNull();
    store.setConfigError("broken");
    store.setConfigError("broken");
    expect(store.getConfigError()).toBe("broken");
    expect(listener).toHaveBeenCalledTimes(1);

    store.setConfigError(null);
    expect(store.getConfigError()).toBeNull();
    expect(listener).toHaveBeenCalledTimes(2);
  });

  it("notifies subscribers on change and stops after unsubscribe", () => {
    const store = new HostStore();
    const listener = vi.fn();
    const unsubscribe = store.subscribe(listener);

    store.setHost("h1", "laptop");
    expect(listener).toHaveBeenCalledTimes(1);

    unsubscribe();
    store.setStatus("h1", "connected");
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("ignores updates for unknown hosts instead of throwing", () => {
    const store = new HostStore();
    expect(() => store.applyAgentUpdate("nope", { kind: "remove", agentId: "a" })).not.toThrow();
    expect(() =>
      store.applyWorkspaceUpdate("nope", { kind: "remove", workspaceId: "w" }),
    ).not.toThrow();
    expect(store.snapshot()).toEqual([]);
  });
});
