import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { Writable } from "node:stream";
import os from "node:os";
import path from "node:path";
import pino from "pino";
import { createPaseoDaemon, hashDaemonPassword } from "@getpaseo/server";
import { AgentStore } from "./agent-store.js";
import { createHostConnection } from "./host-connection.js";

interface Harness {
  port: number;
  stop: () => Promise<void>;
}

/**
 * A pino destination that counts log lines containing `needle`, so a test can
 * observe how many times the daemon rejected a connection attempt without
 * reaching into daemon internals.
 */
function createLogCounter(needle: string): { logger: pino.Logger; count: () => number } {
  let count = 0;
  const stream = new Writable({
    write(chunk, _encoding, callback) {
      if (chunk.toString().includes(needle)) count += 1;
      callback();
    },
  });
  return { logger: pino({ level: "warn" }, stream), count: () => count };
}

async function startDaemon(options?: {
  auth?: { password: string };
  logger?: pino.Logger;
}): Promise<Harness> {
  const root = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-daemon-"));
  const paseoHome = path.join(root, ".paseo");
  await mkdir(paseoHome, { recursive: true });
  const staticDir = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-static-"));

  const daemon = await createPaseoDaemon(
    {
      listen: "127.0.0.1:0",
      paseoHome,
      corsAllowedOrigins: [],
      hostnames: true,
      mcpEnabled: false,
      staticDir,
      mcpDebug: false,
      agentClients: {},
      agentStoragePath: path.join(paseoHome, "agents"),
      relayEnabled: false,
      relayEndpoint: "relay.paseo.sh:443",
      appBaseUrl: "https://app.paseo.sh",
      ...(options?.auth ? { auth: options.auth } : {}),
    },
    options?.logger ?? pino({ level: "warn" }),
  );

  await daemon.start();
  const target = daemon.getListenTarget();
  if (!target || target.type !== "tcp") throw new Error("expected a TCP listener");

  return {
    port: target.port,
    stop: async () => {
      await daemon.stop().catch(() => undefined);
      await rm(root, { recursive: true, force: true });
      await rm(staticDir, { recursive: true, force: true });
    },
  };
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("timed out waiting for condition");
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

describe("createHostConnection", () => {
  it("connects, seeds, and records the daemon's serverId", async () => {
    const harness = await startDaemon();
    cleanups.push(harness.stop);

    const store = new AgentStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");

    const host = store.snapshot()[0];
    expect(host?.agents).toEqual([]);
    expect(host?.serverId).toBeTruthy();
  });

  it("reports disconnected when the daemon goes away", async () => {
    const harness = await startDaemon();
    const store = new AgentStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    await harness.stop();

    await waitFor(() => store.snapshot()[0]?.status === "disconnected");
  });

  it("reports connecting again while the SDK retries a lost connection", async () => {
    const harness = await startDaemon();
    const store = new AgentStore();

    // Record every status the store passes through: a reconnect attempt's
    // `connecting` leg can be shorter than any polling interval, so the
    // assertion has to see transitions, not a sampled value.
    const seen: string[] = [];
    store.subscribe(() => {
      const status = store.snapshot()[0]?.status;
      if (status && seen[seen.length - 1] !== status) seen.push(status);
    });

    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "connected");
    const afterConnected = seen.length;
    await harness.stop();

    await waitFor(() => seen.slice(afterConnected).includes("connecting"));
    expect(seen).toContain("connected");
    expect(seen.slice(afterConnected)).toContain("disconnected");
  });

  it("marks a wrong password unauthorized and stops retrying", async () => {
    const rightPassword = "correct-horse-battery-staple";
    const { logger, count } = createLogCounter(
      "Rejected WebSocket connection with invalid daemon password",
    );
    const harness = await startDaemon({
      auth: { password: hashDaemonPassword(rightPassword) },
      logger,
    });
    cleanups.push(harness.stop);

    const store = new AgentStore();
    const connection = createHostConnection({
      entry: {
        id: "h1",
        label: "local",
        type: "directTcp",
        endpoint: `127.0.0.1:${harness.port}`,
        useTls: false,
        password: "wrong-password",
      },
      store,
    });
    cleanups.push(() => connection.close());

    await waitFor(() => store.snapshot()[0]?.status === "unauthorized");

    // At least one rejected attempt got us to "unauthorized". Give the
    // client's exponential-backoff reconnect loop (base delay 1.5s) ample
    // room to have fired again if retries were not actually stopped.
    const rejectionsAtUnauthorized = count();
    expect(rejectionsAtUnauthorized).toBeGreaterThanOrEqual(1);

    await new Promise((resolve) => setTimeout(resolve, 4_000));

    expect(count()).toBe(rejectionsAtUnauthorized);
    expect(store.snapshot()[0]?.status).toBe("unauthorized");
  });
});
