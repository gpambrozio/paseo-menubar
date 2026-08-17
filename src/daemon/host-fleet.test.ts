import { describe, expect, it } from "vitest";
import type { AppConfig, HostEntry } from "../config/host-config.js";
import { AgentStore } from "./agent-store.js";
import { createHostFleet } from "./host-fleet.js";

function directEntry(id: string, overrides: Partial<Extract<HostEntry, { type: "directTcp" }>> = {}) {
  return {
    id,
    label: id,
    type: "directTcp",
    endpoint: "127.0.0.1:6767",
    useTls: false,
    ...overrides,
  } as HostEntry;
}

const relayEntry: HostEntry = {
  id: "r1",
  type: "relay",
  label: "studio",
  offer: {
    v: 2,
    serverId: "srv-2",
    daemonPublicKeyB64: "AAAA",
    relay: { endpoint: "relay.paseo.sh:443", useTls: true },
  },
};

function config(...hosts: HostEntry[]): AppConfig {
  return { version: 1, hosts };
}

interface CreatedConnection {
  entry: HostEntry;
  closed: boolean;
}

/**
 * Stands in for `createHostConnection` with the two store effects the fleet's
 * bookkeeping actually depends on: registering the host on construction, and
 * removing it in `close()`'s tail. `closeDelayMs` widens the window two
 * overlapping fleet mutations would interleave through.
 */
function createFakeConnections(options: { closeDelayMs?: number; failOn?: string[] } = {}) {
  const closeDelayMs = options.closeDelayMs ?? 0;
  const failOn = new Set(options.failOn ?? []);
  const created: CreatedConnection[] = [];
  /** Every construction and teardown, in the order they happened. */
  const events: string[] = [];

  function create({ entry, store }: { entry: HostEntry; store: AgentStore }) {
    if (failOn.has(entry.id)) throw new Error(`cannot build a client for ${entry.id}`);
    events.push(`create:${entry.id}`);
    store.setHost(entry.id, entry.label);
    const record: CreatedConnection = { entry, closed: false };
    created.push(record);
    return {
      async close() {
        events.push(`close:${entry.id}`);
        if (closeDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, closeDelayMs));
        record.closed = true;
        store.removeHost(entry.id);
      },
    };
  }

  return {
    created,
    create,
    events,
    /** Mutable so a test can break a host that connected fine the first time. */
    failOn,
    ids: () => created.map((item) => item.entry.id),
    leaked: () => created.filter((item) => !item.closed).map((item) => item.entry.id),
  };
}

function createFleet(
  connections: ReturnType<typeof createFakeConnections>,
  store = new AgentStore(),
) {
  const failures: string[][] = [];
  const fleet = createHostFleet({
    store,
    onEntryFailures: (entries) => failures.push(entries),
    createConnection: connections.create,
  });
  return { fleet, store, failures };
}

describe("host fleet serialization", () => {
  it("does not let two overlapping applies discard live connections without closing them", async () => {
    const connections = createFakeConnections({ closeDelayMs: 20 });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("a1"), directEntry("a2")));

    // Both start before either finishes: each spends its teardown inside a
    // slow `close()`, which is exactly the window an unserialized fleet would
    // interleave through -- the second generation would clear the map the
    // first had already refilled, stranding live connections nothing closes.
    const second = fleet.apply(config(directEntry("b1")));
    const third = fleet.apply(config(directEntry("c1"), directEntry("c2")));
    await Promise.all([second, third]);

    // Each generation tears down and rebuilds as a unit. Interleaved, the two
    // fight over one map: they close each other's freshly built connections
    // and each other's entries, so closes and creates cross generations.
    expect(connections.events).toEqual([
      "create:a1",
      "create:a2",
      "close:a1",
      "close:a2",
      "create:b1",
      "close:b1",
      "create:c1",
      "create:c2",
    ]);
    // Only the last generation is still live; everything else was closed once.
    expect(connections.leaked()).toEqual(["c1", "c2"]);
    expect(store.snapshot().map((host) => host.hostId)).toEqual(["c1", "c2"]);
  });

  it("runs a retry after the apply it overlaps, not inside it", async () => {
    const connections = createFakeConnections({ closeDelayMs: 20 });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    const apply = fleet.apply(config(directEntry("h2")));
    const retry = fleet.retry("h1");
    await Promise.all([apply, retry]);

    // The retry saw the fleet the apply left behind: h1 is gone from it, so
    // there is nothing to retry and no fourth connection.
    expect(connections.ids()).toEqual(["h1", "h2"]);
    expect(store.snapshot().map((host) => host.hostId)).toEqual(["h2"]);
  });
});

describe("host fleet entry failures", () => {
  it("keeps the rest of the fleet when one entry cannot be used", async () => {
    const connections = createFakeConnections({ failOn: ["bad"] });
    const { fleet, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("good1"), directEntry("bad"), directEntry("good2")));

    // The entry after the bad one still connected.
    expect(connections.ids()).toEqual(["good1", "good2"]);
    expect(failures.at(-1)).toEqual(["bad: cannot build a client for bad"]);
  });

  it("shows the unusable host as invalid rather than hiding it", async () => {
    const connections = createFakeConnections({ failOn: ["bad"] });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("bad", { label: "laptop" })));

    expect(store.snapshot()).toMatchObject([{ hostId: "bad", label: "laptop", status: "invalid" }]);
  });

  it("refuses to build a second connection under an id that already has one", async () => {
    const connections = createFakeConnections();
    const { fleet, store, failures } = createFleet(connections);

    // `AppConfigSchema` rejects this, so it can only arrive from a call site
    // that skipped the schema. The connection map would otherwise overwrite
    // the first entry's connection, leaking a socket nothing can close.
    await fleet.apply(
      config(directEntry("dup", { label: "first" }), directEntry("dup", { label: "second" })),
    );

    expect(connections.ids()).toEqual(["dup"]);
    expect(failures.at(-1)).toEqual(['second: a connection for host id "dup" already exists']);
    expect(store.snapshot()).toMatchObject([{ hostId: "dup", status: "invalid" }]);
  });

  it("clears the failure list once the entries are fixed", async () => {
    const connections = createFakeConnections({ failOn: ["bad"] });
    const { fleet, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("bad")));
    await fleet.apply(config(directEntry("good")));

    expect(failures).toEqual([["bad: cannot build a client for bad"], []]);
  });
});

describe("host fleet fingerprint guard", () => {
  it("no-ops on a config whose host list is unchanged", async () => {
    const connections = createFakeConnections();
    const { fleet, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    // A distinct object with the same hosts: our own config writes come back
    // through the watcher as a fresh parse, and must not churn sockets.
    await fleet.apply(config(directEntry("h1")));

    expect(connections.ids()).toEqual(["h1"]);
    expect(connections.leaked()).toEqual(["h1"]);
    expect(failures).toHaveLength(1);
  });

  it("re-applies when the host list changes", async () => {
    const connections = createFakeConnections();
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    await fleet.apply(config(directEntry("h1", { endpoint: "127.0.0.1:7000" })));

    expect(connections.ids()).toEqual(["h1", "h1"]);
    expect(connections.leaked()).toEqual(["h1"]);
    expect(store.snapshot().map((host) => host.hostId)).toEqual(["h1"]);
  });

  it("re-applies after a rebuild that threw partway", async () => {
    const connections = createFakeConnections();
    const store = new AgentStore();
    let failNextClose = false;
    const fleet = createHostFleet({
      store,
      onEntryFailures: () => undefined,
      createConnection: ({ entry }) => {
        connections.created.push({ entry, closed: false });
        return {
          async close() {
            if (failNextClose) throw new Error("close blew up");
          },
        };
      },
    });

    await fleet.apply(config(directEntry("h1")));
    failNextClose = true;
    await expect(fleet.apply(config(directEntry("h2")))).rejects.toThrow("close blew up");

    // The fingerprint was never claimed, so the same config can be applied
    // again -- a rebuild that died partway must stay repairable.
    failNextClose = false;
    await fleet.apply(config(directEntry("h2")));
    expect(connections.ids()).toEqual(["h1", "h2"]);
  });
});

describe("host fleet retry", () => {
  it("closes the old connection before building the new one", async () => {
    const connections = createFakeConnections({ closeDelayMs: 5 });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    await fleet.retry("h1");

    expect(connections.ids()).toEqual(["h1", "h1"]);
    expect(connections.created[0]?.closed).toBe(true);
    // `close()` removes the host from the store, so building the replacement
    // first would leave a live connection the store can no longer see: every
    // later status update would early-return on a missing host.
    expect(store.snapshot().map((host) => host.hostId)).toEqual(["h1"]);
  });

  it("names the host when the rebuild itself fails", async () => {
    const connections = createFakeConnections();
    const { fleet, store, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("h1", { label: "laptop" })));
    expect(failures.at(-1)).toEqual([]);

    connections.failOn.add("h1");
    await fleet.retry("h1");

    // The tray shows `invalid` either way; without the report the error row
    // never says which host stopped working or why.
    expect(store.snapshot()).toMatchObject([{ hostId: "h1", status: "invalid" }]);
    expect(failures.at(-1)).toEqual(["laptop: cannot build a client for h1"]);
  });

  it("clears the host's failure once a retry rebuilds it", async () => {
    const connections = createFakeConnections({ failOn: ["h1"] });
    const { fleet, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("h1", { label: "laptop" }), directEntry("h2")));
    expect(failures.at(-1)).toEqual(["laptop: cannot build a client for h1"]);

    connections.failOn.delete("h1");
    await fleet.retry("h1");

    expect(failures.at(-1)).toEqual([]);
  });

  it("leaves the other hosts' failures alone when one is retried", async () => {
    const connections = createFakeConnections({ failOn: ["h1", "h2"] });
    const { fleet, failures } = createFleet(connections);

    await fleet.apply(config(directEntry("h1"), directEntry("h2")));

    connections.failOn.delete("h1");
    await fleet.retry("h1");

    expect(failures.at(-1)).toEqual(["h2: cannot build a client for h2"]);
  });

  it("ignores a host that is not in the fleet", async () => {
    const connections = createFakeConnections();
    const { fleet } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    await fleet.retry("nope");

    expect(connections.ids()).toEqual(["h1"]);
  });
});

describe("host fleet web base URLs", () => {
  it("derives a direct host's web UI from its endpoint", async () => {
    const connections = createFakeConnections();
    const { fleet } = createFleet(connections);

    await fleet.apply(
      config(
        directEntry("plain", { endpoint: "192.168.1.4:6767" }),
        directEntry("tls", { endpoint: "daemon.example.com:443", useTls: true }),
        relayEntry,
      ),
    );

    expect(fleet.webBaseUrlFor("plain")).toBe("http://192.168.1.4:6767");
    expect(fleet.webBaseUrlFor("tls")).toBe("https://daemon.example.com:443");
    // A relay is a socket tunnel, not an HTTP origin, so there is no fallback.
    expect(fleet.webBaseUrlFor("r1")).toBeUndefined();
    expect(fleet.webBaseUrlFor("not-a-host")).toBeUndefined();
  });

  it("forgets a host's URL once it leaves the config", async () => {
    const connections = createFakeConnections();
    const { fleet } = createFleet(connections);

    await fleet.apply(config(directEntry("h1")));
    await fleet.apply(config(directEntry("h2")));

    expect(fleet.webBaseUrlFor("h1")).toBeUndefined();
    expect(fleet.webBaseUrlFor("h2")).toBe("http://127.0.0.1:6767");
  });
});

describe("host fleet web fallback", () => {
  it("picks the first connected direct host in config order, skipping a relay", async () => {
    const connections = createFakeConnections();
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(relayEntry, directEntry("h1", { endpoint: "192.168.1.4:6767" })));
    store.setStatus("h1", "connected");

    expect(fleet.firstWebBaseUrl()).toBe("http://192.168.1.4:6767");
  });

  it("skips a host whose entry never became a live connection", async () => {
    // "bad" has a perfectly good directTcp endpoint -- it fails to build a
    // client for some other reason -- so its entry sits in `appliedHosts`
    // with a URL `webBaseUrlFor` would happily compute. Offering that URL
    // would send the user to a host that never connected.
    const connections = createFakeConnections({ failOn: ["bad"] });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("bad"), directEntry("good", { endpoint: "10.0.0.9:6767" })));
    store.setStatus("good", "connected");

    expect(fleet.firstWebBaseUrl()).toBe("http://10.0.0.9:6767");
  });

  it("returns undefined when no host is both live and a direct connection", async () => {
    const connections = createFakeConnections({ failOn: ["bad"] });
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("bad"), relayEntry));
    store.setStatus("r1", "connected");

    expect(fleet.firstWebBaseUrl()).toBeUndefined();
  });

  it("does not offer a host that is still connecting", async () => {
    const connections = createFakeConnections();
    const { fleet } = createFleet(connections);

    await fleet.apply(config(directEntry("h1", { endpoint: "10.0.0.1:6767" })));
    // Status stays at its default "connecting": the fake connection was
    // built, but nothing ever reported it as answered.

    expect(fleet.firstWebBaseUrl()).toBeUndefined();
  });

  it("does not offer a disconnected host", async () => {
    const connections = createFakeConnections();
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("h1", { endpoint: "10.0.0.1:6767" })));
    store.setStatus("h1", "disconnected");

    expect(fleet.firstWebBaseUrl()).toBeUndefined();
  });

  it("does not offer an unauthorized host", async () => {
    const connections = createFakeConnections();
    const { fleet, store } = createFleet(connections);

    await fleet.apply(config(directEntry("h1", { endpoint: "10.0.0.1:6767" })));
    store.setStatus("h1", "unauthorized");

    expect(fleet.firstWebBaseUrl()).toBeUndefined();
  });

  it("skips connecting, disconnected, and unauthorized hosts to offer the one that is connected", async () => {
    const connections = createFakeConnections();
    const { fleet, store } = createFleet(connections);

    await fleet.apply(
      config(
        directEntry("connecting", { endpoint: "10.0.0.1:6767" }),
        directEntry("down", { endpoint: "10.0.0.2:6767" }),
        directEntry("locked", { endpoint: "10.0.0.3:6767" }),
        directEntry("up", { endpoint: "10.0.0.4:6767" }),
      ),
    );
    store.setStatus("down", "disconnected");
    store.setStatus("locked", "unauthorized");
    store.setStatus("up", "connected");

    expect(fleet.firstWebBaseUrl()).toBe("http://10.0.0.4:6767");
  });
});

describe("host fleet shutdown", () => {
  it("closes every live connection", async () => {
    const connections = createFakeConnections();
    const { fleet } = createFleet(connections);

    await fleet.apply(config(directEntry("h1"), directEntry("h2")));
    fleet.closeAll();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(connections.leaked()).toEqual([]);
  });
});
