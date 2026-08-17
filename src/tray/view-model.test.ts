import { describe, expect, it } from "vitest";
import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
} from "@getpaseo/protocol/messages";
import type { HostSnapshot } from "../daemon/host-store.js";
import { deriveTrayViewModel } from "./view-model.js";

function agent(id: string, overrides: Partial<AgentSnapshotPayload> = {}): AgentSnapshotPayload {
  return {
    id,
    provider: "claude",
    cwd: `/work/${id}`,
    workspaceId: "w1",
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

function host(
  workspaces: WorkspaceDescriptorPayload[],
  overrides: Partial<HostSnapshot> = {},
): HostSnapshot {
  return {
    hostId: "h1",
    label: "laptop",
    status: "connected",
    serverId: "srv-1",
    workspaces,
    agents: [],
    workspacesTruncated: false,
    agentsTruncated: false,
    ...overrides,
  };
}

describe("deriveTrayViewModel", () => {
  it("is idle with no workspaces", () => {
    const model = deriveTrayViewModel([host([])]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("is idle when everything is done, because done is the resting state", () => {
    const model = deriveTrayViewModel([host([workspace("w1"), workspace("w2")])]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
    expect(model.sections.map((s) => s.bucket)).toEqual(["done"]);
  });

  it("is working when a workspace is running", () => {
    const model = deriveTrayViewModel([host([workspace("w1", { status: "running" })])]);
    expect(model.icon).toBe("working");
    expect(model.count).toBe(0);
  });

  it("lets a counted bucket outrank running", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1", { status: "running" }), workspace("w2", { status: "attention" })]),
    ]);
    expect(model.icon).toBe("attention");
    expect(model.count).toBe(1);
  });

  it("counts needs_input, failed, and attention but never done or running", () => {
    const model = deriveTrayViewModel([
      host([
        workspace("a", { status: "needs_input" }),
        workspace("b", { status: "failed" }),
        workspace("c", { status: "attention" }),
        workspace("d", { status: "running" }),
        workspace("e", { status: "done" }),
      ]),
    ]);
    expect(model.count).toBe(3);
    expect(model.icon).toBe("attention");
  });

  it("orders sections the way the Paseo sidebar does and omits empty ones", () => {
    const model = deriveTrayViewModel([
      host([
        workspace("e", { status: "done" }),
        workspace("d", { status: "running" }),
        workspace("c", { status: "attention" }),
        workspace("a", { status: "needs_input" }),
      ]),
    ]);
    // No `failed` workspace, so no `Failed` section.
    expect(model.sections.map((s) => s.bucket)).toEqual([
      "needs_input",
      "attention",
      "running",
      "done",
    ]);
  });

  it("puts done workspaces in a flat section, not a submenu", () => {
    const model = deriveTrayViewModel([host([workspace("w1", { status: "done" })])]);
    const done = model.sections.find((s) => s.bucket === "done");
    expect(done?.rows.map((row) => row.workspaceId)).toEqual(["w1"]);
  });

  it("takes the bucket from the daemon rather than deriving one", () => {
    // The workspace's own agent is idle and wants nothing; the daemon still
    // says `needs_input`, and the daemon wins.
    const model = deriveTrayViewModel([
      host([workspace("w1", { status: "needs_input" })], { agents: [agent("a1")] }),
    ]);
    expect(model.sections.map((s) => s.bucket)).toEqual(["needs_input"]);
    expect(model.count).toBe(1);
  });

  it("excludes workspaces being archived from counts and rows", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1", { status: "needs_input", archivingAt: "2026-08-16T00:00:00.000Z" })]),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
    expect(model.sections).toEqual([]);
  });

  it("excludes a disconnected host's workspaces from counts", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1", { status: "needs_input" })], { status: "disconnected" }),
    ]);
    expect(model.icon).toBe("idle");
    expect(model.count).toBe(0);
  });

  it("carries the workspace's own name and project, not a derived label", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1", { name: "fix-login", projectDisplayName: "paseo-icon" })]),
    ]);
    expect(model.sections[0]?.rows[0]).toMatchObject({
      label: "fix-login",
      projectName: "paseo-icon",
    });
  });

  it("carries the diff stat, and null when the daemon has none", () => {
    const model = deriveTrayViewModel([
      host([
        workspace("w1", { diffStat: { additions: 12, deletions: 3 } }),
        workspace("w2", { diffStat: null }),
      ]),
    ]);
    const rows = model.sections[0]?.rows ?? [];
    expect(rows[0]?.diff).toEqual({ additions: 12, deletions: 3 });
    expect(rows[1]?.diff).toBeNull();
  });

  it("omits the host label with a single host and includes it with two", () => {
    const single = deriveTrayViewModel([host([workspace("w1")])]);
    expect(single.sections[0]?.rows[0]?.hostLabel).toBeNull();

    const multiple = deriveTrayViewModel([
      host([workspace("w1")]),
      host([], { hostId: "h2", label: "studio", serverId: "srv-2" }),
    ]);
    expect(multiple.sections[0]?.rows[0]?.hostLabel).toBe("laptop");
  });

  it("caps rows in a section at 15 and reports the overflow", () => {
    const many = Array.from({ length: 18 }, (_, index) =>
      workspace(`w${index}`, { status: "needs_input" }),
    );
    const model = deriveTrayViewModel([host(many)]);
    const section = model.sections.find((s) => s.bucket === "needs_input");
    expect(section?.rows).toHaveLength(15);
    expect(section?.overflow).toBe(3);
    // The count is the whole bucket, not the visible slice.
    expect(model.count).toBe(18);
  });

  it("names hosts whose workspace list was capped so the rows are never a silent subset", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1")], { workspacesTruncated: true }),
      host([], { hostId: "h2", label: "studio" }),
    ]);
    expect(model.truncatedHosts).toEqual(["laptop"]);
  });

  it("names hosts whose agent page was capped, because their click targets may be missing", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1")], { agentsTruncated: true }),
      host([], { hostId: "h2", label: "studio" }),
    ]);
    expect(model.agentIndexTruncatedHosts).toEqual(["laptop"]);
    expect(model.truncatedHosts).toEqual([]);
  });

  it("ignores truncation on a host whose workspaces are excluded anyway", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1")], {
        status: "disconnected",
        workspacesTruncated: true,
        agentsTruncated: true,
      }),
    ]);
    expect(model.truncatedHosts).toEqual([]);
    expect(model.agentIndexTruncatedHosts).toEqual([]);
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

  it("carries a configuration error through to the menu, keeping the last good hosts", () => {
    const model = deriveTrayViewModel([host([workspace("w1", { status: "failed" })])], {
      configError: "config.json\n\nnot valid JSON",
    });
    expect(model.configError).toBe("config.json\n\nnot valid JSON");
    expect(model.count).toBe(1);
  });

  it("has no configuration error by default", () => {
    expect(deriveTrayViewModel([host([])]).configError).toBeNull();
  });

  it("carries serverId on rows so a click can build a deep link", () => {
    const model = deriveTrayViewModel([host([workspace("w1")])]);
    expect(model.sections[0]?.rows[0]).toMatchObject({ serverId: "srv-1", workspaceId: "w1" });
  });
});

describe("deriveTrayViewModel click targets", () => {
  function rowFor(snapshot: HostSnapshot) {
    return deriveTrayViewModel([snapshot]).sections[0]?.rows[0];
  }

  it("opens the workspace's only agent", () => {
    const row = rowFor(host([workspace("w1")], { agents: [agent("a1")] }));
    expect(row?.agentId).toBe("a1");
  });

  it("has no target when the workspace has no agent", () => {
    const row = rowFor(host([workspace("w1")], { agents: [] }));
    expect(row?.agentId).toBeNull();
  });

  it("ignores agents belonging to another workspace", () => {
    const row = rowFor(host([workspace("w1")], { agents: [agent("a1", { workspaceId: "w2" })] }));
    expect(row?.agentId).toBeNull();
  });

  it("picks the most urgent agent by the daemon's own status priority", () => {
    // getAgentStatusPriority: pending permission 0, error 1, running 2,
    // initializing 3, everything else 4. Lower is more urgent.
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("idle", { status: "idle" }),
          agent("running", { status: "running" }),
          agent("errored", { status: "error" }),
        ],
      }),
    );
    expect(row?.agentId).toBe("errored");
  });

  it("ranks a pending permission above an error", () => {
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("errored", { status: "error" }),
          agent("asking", {
            status: "idle",
            attentionReason: "permission",
            requiresAttention: true,
          }),
        ],
      }),
    );
    expect(row?.agentId).toBe("asking");
  });

  it("breaks a priority tie on updatedAt, newest first, then on id", () => {
    const byTime = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("older", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
          agent("newer", { status: "running", updatedAt: "2026-08-16T01:00:00.000Z" }),
        ],
      }),
    );
    expect(byTime?.agentId).toBe("newer");

    const byId = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("b", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
          agent("a", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
        ],
      }),
    );
    expect(byId?.agentId).toBe("a");
  });

  it("never targets an archived agent", () => {
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("gone", { status: "error", archivedAt: "2026-08-16T00:00:00.000Z" }),
          agent("live", { status: "idle" }),
        ],
      }),
    );
    expect(row?.agentId).toBe("live");
  });
});
