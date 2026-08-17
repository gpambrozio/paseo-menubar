import { describe, expect, it } from "vitest";
import type { AgentSnapshotPayload } from "@getpaseo/protocol/messages";
import type { HostAgents } from "../daemon/agent-store.js";
import { deriveTrayViewModel } from "./view-model.js";

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

function host(agents: AgentSnapshotPayload[], overrides: Partial<HostAgents> = {}): HostAgents {
  return {
    hostId: "h1",
    label: "laptop",
    status: "connected",
    serverId: "srv-1",
    agents,
    truncated: false,
    ...overrides,
  };
}

describe("deriveTrayViewModel", () => {
  it("is idle with no agents", () => {
    const model = deriveTrayViewModel([host([])]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("is working when an agent is running", () => {
    const model = deriveTrayViewModel([host([agent("a", { status: "running" })])]);
    expect(model.icon).toBe("working");
    expect(model.count).toBe(0);
    expect(model.sections[0]?.rows[0]?.detail).toBeNull();
  });

  it("treats initializing as working", () => {
    const model = deriveTrayViewModel([host([agent("a", { status: "initializing" })])]);
    expect(model.icon).toBe("working");
  });

  it("lets attention outrank running", () => {
    const model = deriveTrayViewModel([
      host([
        agent("a", { status: "running" }),
        agent("b", { requiresAttention: true, attentionReason: "finished" }),
      ]),
    ]);
    expect(model.icon).toBe("attention");
    expect(model.count).toBe(1);
    expect(model.sections[0]?.rows[0]?.detail).toBe("finished");
  });

  it("counts every attention reason in one number", () => {
    const model = deriveTrayViewModel([
      host([
        agent("a", { requiresAttention: true, attentionReason: "finished" }),
        agent("b", { requiresAttention: true, attentionReason: "permission" }),
        agent("c", { requiresAttention: true, attentionReason: "error" }),
      ]),
    ]);
    expect(model.count).toBe(3);
    expect(model.sections[0]?.rows[0]?.detail).toBe("finished");
    expect(model.sections[0]?.rows[1]?.detail).toBe("permission");
    expect(model.sections[0]?.rows[2]?.detail).toBe("error");
  });

  it("excludes archived agents from counts and rows", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true, archivedAt: "2026-08-16T00:00:00.000Z" })]),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
    expect(model.sections).toEqual([]);
  });

  it("excludes a disconnected host's agents from counts", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true })], { status: "disconnected" }),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("groups by state with attention first", () => {
    const model = deriveTrayViewModel([
      host([
        agent("idle-one"),
        agent("run", { status: "running" }),
        agent("att", { requiresAttention: true, attentionReason: "permission" }),
      ]),
    ]);
    expect(model.sections.map((s) => s.kind)).toEqual(["attention", "working", "idle"]);
    expect(model.sections[0]?.rows[0]?.agentId).toBe("att");
    expect(model.sections[0]?.rows[0]?.detail).toBe("permission");
    expect(model.sections[1]?.rows[0]?.detail).toBeNull();
    expect(model.sections[2]?.rows[0]?.detail).toBeNull();
  });

  it("omits the host label with a single host and includes it with two", () => {
    const single = deriveTrayViewModel([host([agent("a", { requiresAttention: true })])]);
    expect(single.sections[0]?.rows[0]?.hostLabel).toBeNull();

    const multiple = deriveTrayViewModel([
      host([agent("a", { requiresAttention: true })]),
      host([], { hostId: "h2", label: "studio", serverId: "srv-2" }),
    ]);
    expect(multiple.sections[0]?.rows[0]?.hostLabel).toBe("laptop");
  });

  it("falls back to the cwd basename when title is null", () => {
    const model = deriveTrayViewModel([
      host([agent("a", { title: null, cwd: "/work/api-server", requiresAttention: true })]),
    ]);
    expect(model.sections[0]?.rows[0]?.label).toBe("api-server");
  });

  it("caps attention rows at 15 and reports the overflow", () => {
    const many = Array.from({ length: 18 }, (_, index) =>
      agent(`a${index}`, { requiresAttention: true, attentionReason: "finished" }),
    );
    const model = deriveTrayViewModel([host(many)]);
    const attention = model.sections.find((s) => s.kind === "attention");
    expect(attention?.rows).toHaveLength(15);
    expect(attention?.overflow).toBe(3);
  });

  it("names hosts whose agent list was capped so the count is never a silent floor", () => {
    const model = deriveTrayViewModel([
      host([agent("a")], { truncated: true }),
      host([], { hostId: "h2", label: "studio", truncated: false }),
    ]);
    expect(model.truncatedHosts).toEqual(["laptop"]);
  });

  it("ignores truncation on a host whose agents are excluded anyway", () => {
    const model = deriveTrayViewModel([
      host([agent("a")], { status: "disconnected", truncated: true }),
    ]);
    expect(model.truncatedHosts).toEqual([]);
  });

  it("reports host connection state for the status footer", () => {
    const model = deriveTrayViewModel([
      host([], { status: "connected" }),
      host([], { hostId: "h2", label: "studio", status: "disconnected", serverId: null }),
    ]);
    expect(model.hostStatuses).toEqual([
      { hostId: "h1", label: "laptop", status: "connected" },
      { hostId: "h2", label: "studio", status: "disconnected" },
    ]);
  });

  it("carries serverId on rows so a click can build a deep link", () => {
    const model = deriveTrayViewModel([host([agent("a", { requiresAttention: true })])]);
    expect(model.sections[0]?.rows[0]).toMatchObject({ serverId: "srv-1", agentId: "a" });
  });
});
