import { afterEach, describe, expect, it } from "vitest";
import { cp, mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { hostEntriesFromRegistry, readRegistry, registryLevelDbDir } from "./paseo-registry.js";

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "paseo-registry-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

function leveldbPath(appSupportDir: string, appDirName: string): string {
  return path.join(appSupportDir, appDirName, "Local Storage", "leveldb");
}

/** Creates `<appSupportDir>/<appDirName>/Local Storage/leveldb/`, empty. */
async function seedEmptyLevelDbDir(appSupportDir: string, appDirName: string): Promise<string> {
  const dir = leveldbPath(appSupportDir, appDirName);
  await mkdir(dir, { recursive: true });
  return dir;
}

/** Populates `<appSupportDir>/<appDirName>/Local Storage/leveldb/` with a fixture's files. */
async function seedFixture(appSupportDir: string, appDirName: string, fixture: string): Promise<string> {
  const dir = await seedEmptyLevelDbDir(appSupportDir, appDirName);
  await cp(path.join(FIXTURES, fixture), dir, { recursive: true });
  return dir;
}

function profile(overrides: Record<string, unknown> = {}) {
  return {
    serverId: "srv_one",
    label: "Mac.localdomain",
    lifecycle: {},
    connections: [{ id: "direct:localhost:6767", type: "directTcp", endpoint: "localhost:6767" }],
    preferredConnectionId: "direct:localhost:6767",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("hostEntriesFromRegistry", () => {
  it("maps a direct TCP host, keying it by serverId", () => {
    const { hosts, failures } = hostEntriesFromRegistry(JSON.stringify([profile()]));
    expect(failures).toEqual([]);
    expect(hosts).toEqual([
      {
        id: "srv_one",
        label: "Mac.localdomain",
        type: "directTcp",
        endpoint: "localhost:6767",
        useTls: false,
      },
    ]);
  });

  it("rebuilds a relay offer from the stored connection", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          serverId: "srv_two",
          label: "ai-mbp.local",
          connections: [
            {
              id: "relay:wss:relay.paseo.sh:443",
              type: "relay",
              relayEndpoint: "relay.paseo.sh:443",
              useTls: true,
              daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
            },
          ],
          preferredConnectionId: "relay:wss:relay.paseo.sh:443",
        }),
      ]),
    );
    expect(hosts[0]).toEqual({
      id: "srv_two",
      label: "ai-mbp.local",
      type: "relay",
      offer: {
        v: 2,
        serverId: "srv_two",
        daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("keeps two relay hosts apart even though their connection ids are identical", () => {
    const shared = {
      id: "relay:wss:relay.paseo.sh:443",
      type: "relay",
      relayEndpoint: "relay.paseo.sh:443",
      useTls: true,
      daemonPublicKeyB64: "AAAA",
    };
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({ serverId: "srv_a", connections: [shared], preferredConnectionId: shared.id }),
        profile({ serverId: "srv_b", connections: [shared], preferredConnectionId: shared.id }),
      ]),
    );
    expect(hosts.map((host) => host.id)).toEqual(["srv_a", "srv_b"]);
  });

  it("keeps only the first profile for a repeated serverId and names the loser", () => {
    const { hosts, failures } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({ label: "Direct one" }),
        profile({
          label: "Relay twin",
          connections: [
            {
              id: "relay:wss:relay.paseo.sh:443",
              type: "relay",
              relayEndpoint: "relay.paseo.sh:443",
              useTls: true,
              daemonPublicKeyB64: "AAAA",
            },
          ],
          preferredConnectionId: "relay:wss:relay.paseo.sh:443",
        }),
      ]),
    );

    // Both profiles carry serverId `srv_one`. The id keys the fleet's
    // connection map, so admitting both leaves one live socket labelled and
    // typed as the other -- the relay row would answer for the direct
    // connection, and `webBaseUrlFor` would return undefined for it.
    expect(hosts).toHaveLength(1);
    expect(hosts[0]).toMatchObject({ id: "srv_one", label: "Direct one", type: "directTcp" });
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("Relay twin");
    expect(failures[0]).toContain("srv_one");
  });

  it("falls back to a supported connection when the preferred one is not", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "pipe:1", type: "directPipe", path: "/tmp/sock" },
            { id: "direct:1", type: "directTcp", endpoint: "10.0.0.9:6767" },
          ],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toHaveLength(1);
    expect(hosts[0]).toMatchObject({ type: "directTcp", endpoint: "10.0.0.9:6767" });
  });

  it("drops a host with no supported connection and names it in failures", () => {
    const { hosts, failures } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          label: "Pipe only",
          connections: [{ id: "pipe:1", type: "directPipe", path: "/tmp/sock" }],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toEqual([]);
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("Pipe only");
  });

  it("carries a direct host's password through", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "d", type: "directTcp", endpoint: "10.0.0.9:6767", useTls: true, password: "hunter2" },
          ],
          preferredConnectionId: "d",
        }),
      ]),
    );
    expect(hosts[0]).toMatchObject({ useTls: true, password: "hunter2" });
  });

  it("throws on JSON that is not an array of profiles", () => {
    expect(() => hostEntriesFromRegistry('{"nope":true}')).toThrow();
  });

  it("throws on malformed JSON rather than returning an empty host list", () => {
    expect(() => hostEntriesFromRegistry("{{{")).toThrow();
  });
});

describe("registryLevelDbDir", () => {
  it("returns the Paseo path when that directory exists", async () => {
    const appSupportDir = await tempDir();
    const expected = await seedEmptyLevelDbDir(appSupportDir, "Paseo");

    expect(await registryLevelDbDir(appSupportDir)).toBe(expected);
  });

  it("falls back to @getpaseo/desktop when only that one exists", async () => {
    const appSupportDir = await tempDir();
    const expected = await seedEmptyLevelDbDir(appSupportDir, "@getpaseo/desktop");

    expect(await registryLevelDbDir(appSupportDir)).toBe(expected);
  });

  it("prefers Paseo when both exist", async () => {
    const appSupportDir = await tempDir();
    const expected = await seedEmptyLevelDbDir(appSupportDir, "Paseo");
    await seedEmptyLevelDbDir(appSupportDir, "@getpaseo/desktop");

    expect(await registryLevelDbDir(appSupportDir)).toBe(expected);
  });

  it("throws naming both probed paths when neither exists", async () => {
    const appSupportDir = await tempDir();
    const paseoPath = leveldbPath(appSupportDir, "Paseo");
    const desktopPath = leveldbPath(appSupportDir, "@getpaseo/desktop");

    await expect(registryLevelDbDir(appSupportDir)).rejects.toSatisfy((error: unknown) => {
      const message = (error as Error).message;
      return message.includes(paseoPath) && message.includes(desktopPath);
    });
  });
});

describe("readRegistry", () => {
  it("returns null when the directory exists but holds no registry key", async () => {
    const appSupportDir = await tempDir();
    await seedFixture(appSupportDir, "Paseo", "deleted");

    expect(await readRegistry(appSupportDir)).toBeNull();
  });

  it("returns mapped hosts when pointed at a real fixture", async () => {
    const appSupportDir = await tempDir();
    await seedFixture(appSupportDir, "Paseo", "log-only");

    expect(await readRegistry(appSupportDir)).toEqual({
      hosts: [
        {
          id: "srv_fixture01",
          label: "log-only",
          type: "directTcp",
          endpoint: "localhost:6767",
          useTls: false,
        },
      ],
      failures: [],
    });
  });
});
