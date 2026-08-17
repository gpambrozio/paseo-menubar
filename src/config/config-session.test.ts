import { afterEach, describe, expect, it } from "vitest";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createConfigSession } from "./config-session.js";
import {
  configPath,
  loadConfig,
  saveConfig,
  type AppConfig,
  type HostEntry,
} from "./host-config.js";

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-session-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

function hostEntry(id: string, label = id): HostEntry {
  return { id, label, type: "directTcp", endpoint: "10.0.0.1:6767", useTls: false };
}

/**
 * A session over `dir` that records what it would have applied and every
 * message it pushed at the error row, since those two callbacks are the whole
 * of its output.
 */
function createSession(dir: string) {
  const applied: AppConfig[] = [];
  const errors: (string | null)[] = [];
  const session = createConfigSession({
    configDir: dir,
    onConfigError: (message) => errors.push(message),
    applyConfig: async (config) => {
      applied.push(config);
    },
    createId: () => "seed-id",
  });
  return { session, applied, errors };
}

async function writeRaw(dir: string, contents: string): Promise<void> {
  await writeFile(configPath(dir), contents, "utf8");
}

describe("config session first run", () => {
  it("seeds the local daemon so a fresh install needs no configuration", async () => {
    const dir = await tempDir();
    const { session, applied, errors } = createSession(dir);

    await session.start();

    const seeded = {
      version: 1,
      hosts: [
        {
          id: "seed-id",
          label: "Local",
          type: "directTcp",
          endpoint: "127.0.0.1:6767",
          useTls: false,
        },
      ],
    };
    expect(applied).toEqual([seeded]);
    // Written, not just applied: the next launch must find the same host
    // rather than seeding a second one under a new id.
    expect(await loadConfig(dir)).toEqual(seeded);
    expect(errors).toEqual([]);
  });

  it("leaves a config that already has hosts alone", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1", "laptop")] });
    const { session, applied } = createSession(dir);

    await session.start();

    expect(applied).toEqual([{ version: 1, hosts: [hostEntry("h1", "laptop")] }]);
    expect((await loadConfig(dir)).hosts.map((host) => host.id)).toEqual(["h1"]);
  });

  it("comes up with no hosts and names the file when it cannot be read", async () => {
    const dir = await tempDir();
    await writeRaw(dir, "{ not json");
    const { session, applied, errors } = createSession(dir);

    // A menu-bar app that refuses to start leaves the user nothing to fix it
    // with, so the tray comes up empty and the row explains why.
    await session.start();

    expect(applied).toEqual([{ version: 1, hosts: [] }]);
    expect(errors.at(-1)).toContain(configPath(dir));
    expect(errors.at(-1)).toContain("not valid JSON");
  });
});

describe("config session reload", () => {
  it("applies the new config and clears the previous file error", async () => {
    const dir = await tempDir();
    await writeRaw(dir, "{ not json");
    const { session, applied, errors } = createSession(dir);
    await session.start();
    expect(errors.at(-1)).not.toBeNull();

    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    await session.reload();

    expect(applied.at(-1)).toEqual({ version: 1, hosts: [hostEntry("h1")] });
    expect(errors.at(-1)).toBeNull();
  });

  it("keeps the last known-good state when the file stops parsing", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, applied, errors } = createSession(dir);
    await session.start();

    await writeRaw(dir, "{ not json");
    await session.reload();

    // Nothing was applied on top of the good generation: the live hosts keep
    // running and the icon keeps meaning something. Silently reverting to
    // defaults here would drop every host on a stray editor save.
    expect(applied).toEqual([{ version: 1, hosts: [hostEntry("h1")] }]);
    expect(errors.at(-1)).toContain("not valid JSON");
  });

  it("reports a schema violation the same way, without applying it", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, applied, errors } = createSession(dir);
    await session.start();

    const host = { id: "same", label: "laptop", type: "directTcp", endpoint: "a:1", useTls: false };
    await writeRaw(dir, JSON.stringify({ version: 1, hosts: [host, host] }));
    await session.reload();

    expect(applied).toHaveLength(1);
    expect(errors.at(-1)).toContain("Duplicate host id");
  });
});

describe("config session error precedence", () => {
  it("shows the file error while an entry failure is also outstanding", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, errors } = createSession(dir);
    await session.start();

    session.noteEntryFailures(["laptop: cannot build a client"]);
    expect(errors.at(-1)).toContain("laptop: cannot build a client");

    await writeRaw(dir, "{ not json");
    await session.reload();

    // The file being unreadable is why the entries are stale, so it is the
    // one worth showing first.
    expect(errors.at(-1)).toContain("not valid JSON");
    expect(errors.at(-1)).not.toContain("laptop: cannot build a client");
  });

  it("does not let an entry failure clearing clear the file error", async () => {
    const dir = await tempDir();
    await writeRaw(dir, "{ not json");
    const { session, errors } = createSession(dir);
    await session.start();

    session.noteEntryFailures([]);

    expect(errors.at(-1)).toContain("not valid JSON");
  });

  it("does not let a clean reload clear an entry failure", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, errors } = createSession(dir);
    await session.start();
    session.noteEntryFailures(["laptop: cannot build a client"]);

    await session.reload();

    // The two problems are independent: the file parsed, but the host in it
    // still cannot be used, and that is not news the reload gets to discard.
    expect(errors.at(-1)).toContain("laptop: cannot build a client");
  });

  it("uncovers the entry failure once the file is fixed", async () => {
    const dir = await tempDir();
    const { session, errors } = createSession(dir);
    session.noteEntryFailures(["laptop: cannot build a client"]);
    await writeRaw(dir, "{ not json");
    await session.reload();
    expect(errors.at(-1)).toContain("not valid JSON");

    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    await session.reload();

    expect(errors.at(-1)).toContain("laptop: cannot build a client");
  });

  it("reports nothing once both are fixed", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, errors } = createSession(dir);
    await session.start();

    session.noteEntryFailures(["laptop: cannot build a client"]);
    session.noteEntryFailures([]);

    expect(errors.at(-1)).toBeNull();
  });

  it("names the file and every unusable entry in the entry failure message", async () => {
    const dir = await tempDir();
    const { session, errors } = createSession(dir);

    session.noteEntryFailures(["laptop: no", "studio: also no"]);

    expect(errors.at(-1)).toBe(
      `${configPath(dir)}\n\nThese hosts could not be used:\n\nlaptop: no\nstudio: also no`,
    );
  });
});

describe("config session addHost", () => {
  it("appends to what is on disk instead of overwriting it", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session, applied } = createSession(dir);
    await session.start();

    await session.addHost(hostEntry("h2"));

    expect((await loadConfig(dir)).hosts.map((host) => host.id)).toEqual(["h1", "h2"]);
    // The watcher is the single reload path, so adding a host does not apply
    // one; a second apply here would rebuild the fleet twice per added host.
    expect(applied).toHaveLength(1);
  });

  it("rejects rather than dropping the host when the file cannot be read", async () => {
    const dir = await tempDir();
    await writeRaw(dir, "{ not json");
    const { session } = createSession(dir);

    // The caller runs this from a menu click and turns it into a dialog; a
    // swallowed failure would look like the host was added.
    await expect(session.addHost(hostEntry("h2"))).rejects.toThrow(/not valid JSON/);
  });

  it("rejects rather than dropping the host when the file cannot be saved", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [hostEntry("h1")] });
    const { session } = createSession(dir);
    await session.start();

    // main.ts's error text names this case first: a read-only config
    // directory. `saveConfig` writes a temp file into `dir` before renaming
    // it over `config.json`, and that write is what a read-only directory
    // blocks -- the read half of `addHost` still succeeds.
    await chmod(dir, 0o500);
    try {
      await expect(session.addHost(hostEntry("h2"))).rejects.toThrow(/EACCES|permission denied/);
    } finally {
      // Restore write access so `afterEach` can remove the directory.
      await chmod(dir, 0o700);
    }

    expect((await loadConfig(dir)).hosts.map((host) => host.id)).toEqual(["h1"]);
  });
});
