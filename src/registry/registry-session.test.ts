import { describe, expect, it, vi } from "vitest";
import { createRegistrySession } from "./registry-session.js";
import type { AppConfig, HostEntry } from "../config/host-entry.js";
import type { RegistrySnapshot } from "./paseo-registry.js";

function host(id: string): HostEntry {
  return { id, label: id, type: "directTcp", endpoint: "10.0.0.1:6767", useTls: false };
}

function harness(reads: Array<RegistrySnapshot | null | Error>) {
  const applied: AppConfig[] = [];
  const errors: (string | null)[] = [];
  let call = 0;
  const session = createRegistrySession({
    readRegistry: async () => {
      const next = reads[Math.min(call++, reads.length - 1)];
      if (next instanceof Error) throw next;
      return next ?? null;
    },
    // No watcher in tests: refresh() is driven explicitly.
    watch: () => () => undefined,
    applyConfig: async (config) => {
      applied.push(config);
    },
    onConfigError: (message) => errors.push(message),
  });
  return { session, applied, errors };
}

describe("createRegistrySession", () => {
  it("applies the hosts it read and clears the error row", async () => {
    const { session, applied, errors } = harness([{ hosts: [host("a")], failures: [] }]);
    await session.start();
    expect(applied).toHaveLength(1);
    expect(applied[0]!.hosts.map((entry) => entry.id)).toEqual(["a"]);
    expect(errors.at(-1)).toBeNull();
  });

  it("does not rebuild the fleet when the host set is unchanged", async () => {
    const snapshot = { hosts: [host("a")], failures: [] };
    const { session, applied } = harness([snapshot, snapshot]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(1);
  });

  it("rebuilds when the host set actually changes", async () => {
    const { session, applied } = harness([
      { hosts: [host("a")], failures: [] },
      { hosts: [host("a"), host("b")], failures: [] },
    ]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(2);
    expect(applied[1]!.hosts.map((entry) => entry.id)).toEqual(["a", "b"]);
  });

  it("keeps the last known-good hosts when a later read fails", async () => {
    const { session, applied, errors } = harness([
      { hosts: [host("a")], failures: [] },
      new Error("torn read"),
    ]);
    await session.start();
    await session.refresh();
    // Nothing re-applied: the good host set stays live.
    expect(applied).toHaveLength(1);
    expect(errors.at(-1)).toContain("torn read");
  });

  it("applies an empty host set when the registry key is absent", async () => {
    const { session, applied, errors } = harness([{ hosts: [host("a")], failures: [] }, null]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(2);
    expect(applied[1]!.hosts).toEqual([]);
    expect(errors.at(-1)).toContain("No hosts yet");
  });

  it("applies the hosts it got and still reports a partly unreadable database", async () => {
    const { session, applied, errors } = harness([
      {
        hosts: [host("a")],
        failures: [],
        warning: "Could not read 1 of 2 LevelDB file(s) in /db; the host list may be out of date",
      },
    ]);
    await session.start();
    // Both halves matter: dropping the hosts over one torn file empties the
    // tray, and dropping the warning presents a possibly-superseded host list
    // as healthy.
    expect(applied[0]!.hosts.map((entry) => entry.id)).toEqual(["a"]);
    expect(errors.at(-1)).toContain("out of date");
  });

  it("refuses a host set the config schema rejects, and keeps the last good one", async () => {
    const duplicate = host("a");
    const { session, applied, errors } = harness([
      { hosts: [host("a")], failures: [] },
      { hosts: [host("a"), duplicate], failures: [] },
    ]);
    await session.start();
    await session.refresh();

    // Nothing but the first, valid set ever reaches the fleet: two entries
    // under one id would leave an orphaned connection whose socket and
    // subscription never stop.
    expect(applied).toHaveLength(1);
    expect(errors.at(-1)).toContain("Duplicate host id");
  });

  it("refuses a relay entry whose offer fields are empty", async () => {
    const { session, applied, errors } = harness([
      {
        hosts: [
          {
            id: "r1",
            type: "relay",
            offer: {
              v: 2,
              serverId: "srv",
              daemonPublicKeyB64: "",
              relay: { endpoint: "", useTls: true },
            },
          },
        ],
        failures: [],
      },
    ]);
    await session.start();

    // `ConnectionOfferSchema`'s `.min(1)` is the only thing standing between
    // an empty credential from the registry and the connection code.
    expect(applied).toEqual([]);
    expect(errors.at(-1)).toContain("could not be used");
  });

  it("points at the Paseo app when the registry holds an empty host array", async () => {
    // Distinct from an absent key: Paseo is installed and has stored a
    // registry, it is just empty. Without a row the user gets zero hosts, a
    // bare "No workspaces", and -- with config.json and pairing gone -- no
    // route forward at all.
    const { session, applied, errors } = harness([{ hosts: [], failures: [] }]);
    await session.start();
    expect(applied).toHaveLength(1);
    expect(applied[0]!.hosts).toEqual([]);
    expect(errors.at(-1)).toContain("No hosts yet");
  });

  it("re-applies the host set after applyConfig fails, rather than marking it applied", async () => {
    const applied: AppConfig[] = [];
    const errors: (string | null)[] = [];
    let failNext = true;
    const session = createRegistrySession({
      readRegistry: async () => ({ hosts: [host("a")], failures: [] }),
      watch: () => () => undefined,
      applyConfig: async (config) => {
        if (failNext) {
          failNext = false;
          throw new Error("fleet rebuild blew up");
        }
        applied.push(config);
      },
      onConfigError: (message) => errors.push(message),
    });

    await session.start();
    expect(applied).toEqual([]);
    expect(errors.at(-1)).toContain("fleet rebuild blew up");

    // The fingerprint must not have been claimed: the next read sees the same
    // host set, and if it counted as applied the fleet would never receive it
    // -- while the successful read clears the error row, leaving no hosts, no
    // error, and no recovery.
    await session.refresh();
    expect(applied).toHaveLength(1);
    expect(errors.at(-1)).toBeNull();
  });

  it("re-applies the previous host set when the registry reverts after a failed apply", async () => {
    const applied: AppConfig[] = [];
    const errors: (string | null)[] = [];
    let current: HostEntry[] = [host("a")];
    let failFor: string | null = null;
    const session = createRegistrySession({
      readRegistry: async () => ({ hosts: current, failures: [] }),
      watch: () => () => undefined,
      applyConfig: async (config) => {
        if (config.hosts.some((entry) => entry.id === failFor)) throw new Error("fleet rebuild blew up");
        applied.push(config);
      },
      onConfigError: (message) => errors.push(message),
    });

    await session.start();
    expect(applied).toHaveLength(1);

    // The fleet tears down before it rebuilds, so a rebuild that throws
    // leaves it empty -- whatever was live before is gone too.
    current = [host("b")];
    failFor = "b";
    await session.refresh();
    expect(errors.at(-1)).toContain("fleet rebuild blew up");

    // The user reverts in Paseo. That is the same set the session applied
    // first, and treating it as "unchanged" here left the fleet empty with a
    // clear error row: no hosts, no error, no way back.
    current = [host("a")];
    await session.refresh();
    expect(applied).toHaveLength(2);
    expect(applied[1]!.hosts.map((entry) => entry.id)).toEqual(["a"]);
    expect(errors.at(-1)).toBeNull();
  });

  it("keeps the read's own problems in the row when the apply fails", async () => {
    const errors: (string | null)[] = [];
    const session = createRegistrySession({
      readRegistry: async () => ({
        hosts: [host("a")],
        failures: ["Pipe only — no connection the menu bar can use"],
      }),
      watch: () => () => undefined,
      applyConfig: async () => {
        throw new Error("fleet rebuild blew up");
      },
      onConfigError: (message) => errors.push(message),
    });
    await session.start();
    // Both are true at once and both are the user's to act on.
    expect(errors.at(-1)).toContain("Pipe only");
    expect(errors.at(-1)).toContain("fleet rebuild blew up");
  });

  it("runs afterRead after every read, failed ones included", async () => {
    let afterReads = 0;
    const withHook = createRegistrySession({
      readRegistry: async () => {
        throw new Error("Paseo desktop app not found");
      },
      watch: () => () => undefined,
      applyConfig: async () => undefined,
      onConfigError: () => undefined,
      afterRead: () => afterReads++,
    });
    await withHook.start();
    // A failed read is exactly the case that matters: the directory was
    // absent at launch, and this is what re-checks for it on every poll.
    expect(afterReads).toBe(1);
    await withHook.refresh();
    expect(afterReads).toBe(2);
  });

  it("stop() cancels the pending read, the poll, and the watcher", async () => {
    vi.useFakeTimers();
    try {
      let reads = 0;
      let fire = () => {};
      let unwatched = false;
      const session = createRegistrySession({
        readRegistry: async () => {
          reads++;
          return { hosts: [host("a")], failures: [] };
        },
        watch: (onChange) => {
          fire = onChange;
          return () => {
            unwatched = true;
          };
        },
        applyConfig: async () => undefined,
        onConfigError: () => undefined,
        pollMs: 100,
      });

      await session.start();
      expect(reads).toBe(1);

      fire(); // schedules a debounced read that stop() has to cancel
      session.stop();
      await vi.advanceTimersByTimeAsync(2000);

      expect(unwatched).toBe(true);
      expect(reads).toBe(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("surfaces dropped hosts in the error row", async () => {
    const { session, errors } = harness([
      { hosts: [host("a")], failures: ["Pipe only — no connection the menu bar can use"] },
    ]);
    await session.start();
    expect(errors.at(-1)).toContain("Pipe only");
  });

  it("shows a registry problem and a fleet problem at the same time", async () => {
    const { session, errors } = harness([null]);
    await session.start();
    session.noteEntryFailures(["h1 — unreachable"]);
    expect(errors.at(-1)).toContain("No hosts yet");
    expect(errors.at(-1)).toContain("h1 — unreachable");
  });

  it("clearing the fleet's problems does not clear the registry's", async () => {
    const { session, errors } = harness([null]);
    await session.start();
    session.noteEntryFailures(["h1 — unreachable"]);
    session.noteEntryFailures([]);
    expect(errors.at(-1)).toContain("No hosts yet");
    expect(errors.at(-1)).not.toContain("unreachable");
  });

  it("never rejects when the first read fails", async () => {
    const { session, errors } = harness([new Error("nope")]);
    await expect(session.start()).resolves.toBeUndefined();
    expect(errors.at(-1)).toContain("nope");
  });

  it("debounces a burst of watcher events into one read", async () => {
    vi.useFakeTimers();
    try {
      let reads = 0;
      let fire = () => {};
      const session = createRegistrySession({
        readRegistry: async () => {
          reads++;
          return { hosts: [host("a")], failures: [] };
        },
        watch: (onChange) => {
          fire = onChange;
          return () => undefined;
        },
        applyConfig: async () => undefined,
        onConfigError: () => undefined,
      });
      await session.start();
      expect(reads).toBe(1);
      fire();
      fire();
      fire();
      await vi.advanceTimersByTimeAsync(600);
      expect(reads).toBe(2);
      session.stop();
    } finally {
      vi.useRealTimers();
    }
  });
});
