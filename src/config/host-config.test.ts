import { afterEach, describe, expect, it } from "vitest";
import { chmod, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { configPath, loadConfig, saveConfig, watchConfig } from "./host-config.js";

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("host config", () => {
  it("returns an empty host list when the file does not exist", async () => {
    const dir = await tempDir();
    expect(await loadConfig(dir)).toEqual({ version: 1, hosts: [] });
  });

  it("round-trips a direct host", async () => {
    const dir = await tempDir();
    const config = {
      version: 1 as const,
      hosts: [
        {
          id: "h1",
          label: "laptop",
          type: "directTcp" as const,
          endpoint: "localhost:6767",
          useTls: false,
          password: "hunter2",
        },
      ],
    };
    await saveConfig(dir, config);
    expect(await loadConfig(dir)).toEqual(config);
  });

  it("round-trips a relay host with the offer stored verbatim", async () => {
    const dir = await tempDir();
    const config = {
      version: 1 as const,
      hosts: [
        {
          id: "h2",
          label: "studio",
          type: "relay" as const,
          offer: {
            v: 2 as const,
            serverId: "srv-2",
            daemonPublicKeyB64: "AAAA",
            relay: { endpoint: "relay.paseo.sh:443", useTls: true },
          },
        },
      ],
    };
    await saveConfig(dir, config);
    expect(await loadConfig(dir)).toEqual(config);
  });

  it("writes the file 0600 because it holds passwords and relay keys", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [] });
    const info = await stat(configPath(dir));
    expect(info.mode & 0o777).toBe(0o600);
  });

  it("secures a pre-existing file that had looser permissions", async () => {
    const dir = await tempDir();
    // Simulate a config file that was created outside saveConfig (or by an
    // older version of the app) with looser-than-owner-only permissions.
    await writeFile(configPath(dir), JSON.stringify({ version: 1, hosts: [] }), {
      encoding: "utf8",
      mode: 0o644,
    });
    await chmod(configPath(dir), 0o644);
    const before = await stat(configPath(dir));
    expect(before.mode & 0o777).toBe(0o644);

    await saveConfig(dir, { version: 1, hosts: [] });

    const after = await stat(configPath(dir));
    expect(after.mode & 0o777).toBe(0o600);
  });

  it("notifies once when the file changes, debounced", async () => {
    const dir = await tempDir();
    await saveConfig(dir, { version: 1, hosts: [] });

    let calls = 0;
    const stop = watchConfig(dir, () => {
      calls += 1;
    });

    await saveConfig(dir, { version: 1, hosts: [] });
    await saveConfig(dir, { version: 1, hosts: [] });
    await new Promise((resolve) => setTimeout(resolve, 500));
    stop();

    expect(calls).toBe(1);
  });

  it("throws on malformed JSON rather than silently resetting", async () => {
    const dir = await tempDir();
    await writeFile(configPath(dir), "{ not json", "utf8");
    await expect(loadConfig(dir)).rejects.toThrow(/config/i);
  });

  it("throws on a schema violation rather than dropping the bad host", async () => {
    const dir = await tempDir();
    await writeFile(
      configPath(dir),
      JSON.stringify({ version: 1, hosts: [{ id: "h1", type: "directTcp" }] }),
      "utf8",
    );
    await expect(loadConfig(dir)).rejects.toThrow(/config/i);
  });
});
