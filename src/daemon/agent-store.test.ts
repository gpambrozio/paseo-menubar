import { describe, expect, it, vi } from "vitest";
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import { AgentStore } from "./agent-store.js";

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

describe("AgentStore", () => {
  it("seeds a host and reports its agents", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);

    const [host] = store.snapshot();
    expect(host?.label).toBe("laptop");
    expect(host?.agents.map((a) => a.id)).toEqual(["a", "b"]);
  });

  it("applies an upsert as a full replacement", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a", { status: "idle" })]);
    store.applyUpdate("h1", { kind: "upsert", agent: agent("a", { status: "running" }) });

    expect(store.snapshot()[0]?.agents[0]?.status).toBe("running");
  });

  it("applies a remove", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);
    store.applyUpdate("h1", { kind: "remove", agentId: "a" });

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("re-seeding replaces wholesale so a subscription gap cannot strand an agent", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.seed("h1", [agent("a"), agent("b")]);
    store.seed("h1", [agent("b")]);

    expect(store.snapshot()[0]?.agents.map((a) => a.id)).toEqual(["b"]);
  });

  it("tracks status and serverId per host", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    expect(store.snapshot()[0]?.status).toBe("connecting");

    store.setStatus("h1", "connected");
    store.setServerId("h1", "srv-1");

    expect(store.snapshot()[0]?.status).toBe("connected");
    expect(store.snapshot()[0]?.serverId).toBe("srv-1");
  });

  it("removing a host drops it entirely", () => {
    const store = new AgentStore();
    store.setHost("h1", "laptop");
    store.removeHost("h1");
    expect(store.snapshot()).toEqual([]);
  });

  it("notifies subscribers on change and stops after unsubscribe", () => {
    const store = new AgentStore();
    const listener = vi.fn();
    const unsubscribe = store.subscribe(listener);

    store.setHost("h1", "laptop");
    expect(listener).toHaveBeenCalledTimes(1);

    unsubscribe();
    store.setStatus("h1", "connected");
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("ignores updates for unknown hosts instead of throwing", () => {
    const store = new AgentStore();
    expect(() => store.applyUpdate("nope", { kind: "remove", agentId: "a" })).not.toThrow();
    expect(store.snapshot()).toEqual([]);
  });
});
