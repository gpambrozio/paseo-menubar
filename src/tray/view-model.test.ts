import { describe, expect, it } from "vitest";
import type {
  AgentSnapshotPayload,
  WorkspaceDescriptorPayload,
} from "@getpaseo/protocol/messages";
import type { HostSnapshot } from "../daemon/host-store.js";
import { deriveTrayViewModel, resolveHostName } from "./view-model.js";

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
    hostname: null,
    endpointHint: "127.0.0.1:6767",
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
  it("shows the Paseo mark when there are no workspaces at all", () => {
    const model = deriveTrayViewModel([host([])]);
    expect(model.icon).toBe("done");
    expect(model.count).toBe(0);
  });

  it("shows the done icon when everything is done, because done is the resting state", () => {
    const model = deriveTrayViewModel([host([workspace("w1"), workspace("w2")])]);
    expect(model.icon).toBe("done");
    expect(model.count).toBe(0);
    expect(model.sections.map((s) => s.bucket)).toEqual(["done"]);
  });

  it("shows the running icon when a workspace is running and nothing outranks it", () => {
    const model = deriveTrayViewModel([host([workspace("w1", { status: "running" })])]);
    expect(model.icon).toBe("running");
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
    // needs_input outranks every other present bucket, so it is the icon.
    expect(model.icon).toBe("needs_input");
  });

  it("picks the icon of the highest-priority non-empty bucket, section order, not just any present one", () => {
    // failed, running, and done are all present; only failed outranks the
    // others in SECTION_ORDER, so only the ordering rule -- not "any present
    // bucket" -- can produce this result.
    const model = deriveTrayViewModel([
      host([
        workspace("a", { status: "done" }),
        workspace("b", { status: "running" }),
        workspace("c", { status: "failed" }),
      ]),
    ]);
    expect(model.icon).toBe("failed");
  });

  it("orders sections the way the Paseo sidebar does", () => {
    // All five buckets, supplied in an order that matches none of them, so
    // every position in SECTION_ORDER is pinned. Leaving one out here is how a
    // reordered bucket slips through, and a section order that drifts from the
    // sidebar's defeats the whole point of listing workspaces.
    const model = deriveTrayViewModel([
      host([
        workspace("e", { status: "done" }),
        workspace("d", { status: "running" }),
        workspace("c", { status: "attention" }),
        workspace("b", { status: "failed" }),
        workspace("a", { status: "needs_input" }),
      ]),
    ]);
    expect(model.sections.map((s) => s.bucket)).toEqual([
      "needs_input",
      "failed",
      "attention",
      "running",
      "done",
    ]);
  });

  it("omits sections with no workspaces in them", () => {
    const model = deriveTrayViewModel([
      host([workspace("a", { status: "needs_input" }), workspace("e", { status: "done" })]),
    ]);
    expect(model.sections.map((s) => s.bucket)).toEqual(["needs_input", "done"]);
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
    expect(model.icon).toBe("done");
    expect(model.count).toBe(0);
    expect(model.sections).toEqual([]);
  });

  it("excludes a disconnected host's workspaces from counts", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1", { status: "needs_input" })], { status: "disconnected" }),
    ]);
    expect(model.icon).toBe("done");
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

describe("resolveHostName", () => {
  // Every case supplies a distinct value at every tier so a wrong precedence
  // (or a tier silently dropped) picks a different string than the one
  // asserted, rather than one that happens to coincide.
  function tiers(overrides: Partial<Parameters<typeof resolveHostName>[0]> = {}) {
    return {
      label: "explicit-label",
      hostname: "live-hostname",
      serverId: "srv-id",
      endpointHint: "127.0.0.1:6767",
      ...overrides,
    };
  }

  it("prefers the explicit label over everything else", () => {
    expect(resolveHostName(tiers())).toBe("explicit-label");
  });

  it("falls through to the live hostname when there is no label", () => {
    expect(resolveHostName(tiers({ label: undefined }))).toBe("live-hostname");
  });

  it("falls through to the serverId when there is no label or hostname", () => {
    expect(resolveHostName(tiers({ label: undefined, hostname: null }))).toBe("srv-id");
  });

  it("falls through to the entry's own endpoint as the last resort", () => {
    expect(
      resolveHostName(tiers({ label: undefined, hostname: null, serverId: null })),
    ).toBe("127.0.0.1:6767");
  });

  it("pins the seeded Local host to its explicit label even once a hostname arrives", () => {
    // The seeded local host is deliberately labelled "Local" by explicit user
    // request; nothing about a live hostname should ever displace it.
    expect(resolveHostName(tiers({ label: "Local", hostname: "build-box.local" }))).toBe("Local");
  });

  it("drops the mDNS suffix a machine announces itself with", () => {
    const shorten = (hostname: string) => resolveHostName(tiers({ label: undefined, hostname }));
    expect(shorten("build-box.local")).toBe("build-box");
    expect(shorten("build-box.localdomain")).toBe("build-box");
    expect(shorten("AI-MBP.LOCAL")).toBe("AI-MBP");
    // A fully-qualified name may carry the DNS root dot.
    expect(shorten("build-box.local.")).toBe("build-box");
  });

  it("strips the suffix only at the end, and only as a whole label", () => {
    const shorten = (hostname: string) => resolveHostName(tiers({ label: undefined, hostname }));
    // Not a suffix: the machine is simply named this.
    expect(shorten("mylocal")).toBe("mylocal");
    // Not at the end: a real domain that happens to contain the word.
    expect(shorten("box.local.example.com")).toBe("box.local.example.com");
    // `.localdomain` must win over `.local`, or the result keeps a stray `domain`.
    expect(shorten("box.localdomain")).toBe("box");
  });

  it("falls through rather than rendering an empty name", () => {
    // A host announcing itself as exactly ".local" would shorten to nothing.
    expect(resolveHostName(tiers({ label: undefined, hostname: ".local" }))).toBe("srv-id");
    expect(resolveHostName(tiers({ label: undefined, hostname: "" }))).toBe("srv-id");
  });

  it("renders an explicit label verbatim, suffix and all", () => {
    // A user who types `foo.local` means it; only the reported hostname is shortened.
    expect(resolveHostName(tiers({ label: "foo.local" }))).toBe("foo.local");
  });
});

describe("deriveTrayViewModel host naming", () => {
  it("shows the live hostname in the host status line when the entry has no label", () => {
    const model = deriveTrayViewModel([
      host([], { label: undefined, hostname: "build-box.local", serverId: "srv_example" }),
    ]);
    expect(model.hostStatuses).toEqual([
      { hostId: "h1", label: "build-box", status: "connected" },
    ]);
  });

  it("falls back to the serverId in the host status line when the daemon reports no hostname", () => {
    const model = deriveTrayViewModel([
      host([], { label: undefined, hostname: null, serverId: "srv_example" }),
    ]);
    expect(model.hostStatuses).toEqual([
      { hostId: "h1", label: "srv_example", status: "connected" },
    ]);
  });

  it("uses the resolved name, not the raw label, for a truncated-host line", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1")], {
        label: undefined,
        hostname: "build-box.local",
        workspacesTruncated: true,
      }),
    ]);
    expect(model.truncatedHosts).toEqual(["build-box"]);
  });

  it("uses the resolved name for the per-row host label with more than one host", () => {
    const model = deriveTrayViewModel([
      host([workspace("w1")], { label: undefined, hostname: "build-box.local" }),
      host([], { hostId: "h2", label: "studio", serverId: "srv-2" }),
    ]);
    expect(model.sections[0]?.rows[0]?.hostLabel).toBe("build-box");
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

  // Every case below is arranged so the tiebreakers would pick a *different*
  // agent than the rule under test. Ids and timestamps that happen to agree
  // with the rule make a test that passes whether or not the rule is there.
  it("picks the most urgent agent by the daemon's own status priority", () => {
    // getAgentStatusPriority: pending permission 0, error 1, running 2,
    // initializing 3, everything else 4. Lower is more urgent.
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("a-idle", { status: "idle", updatedAt: "2026-08-16T03:00:00.000Z" }),
          agent("b-running", { status: "running", updatedAt: "2026-08-16T02:00:00.000Z" }),
          agent("z-errored", { status: "error", updatedAt: "2026-08-16T01:00:00.000Z" }),
        ],
      }),
    );
    // Last by id and oldest by updatedAt, so only priority can put it first.
    expect(row?.agentId).toBe("z-errored");
  });

  it("ranks a pending permission above an error", () => {
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("a-errored", { status: "error", updatedAt: "2026-08-16T02:00:00.000Z" }),
          agent("z-asking", {
            status: "idle",
            updatedAt: "2026-08-16T01:00:00.000Z",
            attentionReason: "permission",
            requiresAttention: true,
          }),
        ],
      }),
    );
    expect(row?.agentId).toBe("z-asking");
  });

  it("breaks a priority tie on updatedAt, newest first, then on id", () => {
    const byTime = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("a-older", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
          agent("z-newer", { status: "running", updatedAt: "2026-08-16T01:00:00.000Z" }),
        ],
      }),
    );
    // Last by id, so only the timestamp can put it first.
    expect(byTime?.agentId).toBe("z-newer");

    const byId = rowFor(
      host([workspace("w1")], {
        agents: [
          agent("b", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
          agent("a", { status: "running", updatedAt: "2026-08-16T00:00:00.000Z" }),
        ],
      }),
    );
    // Arrival order would leave "b" first, so only the id rule can reorder.
    expect(byId?.agentId).toBe("a");
  });

  it("never targets an archived agent", () => {
    const row = rowFor(
      host([workspace("w1")], {
        agents: [
          // More urgent and newer, so only the archive filter can exclude it.
          agent("gone", {
            status: "error",
            updatedAt: "2026-08-16T02:00:00.000Z",
            archivedAt: "2026-08-16T00:00:00.000Z",
          }),
          agent("live", { status: "idle", updatedAt: "2026-08-16T01:00:00.000Z" }),
        ],
      }),
    );
    expect(row?.agentId).toBe("live");
  });
});
