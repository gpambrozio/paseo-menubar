import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";
import { AgentStore } from "./agent-store.js";
import { createHostConnection } from "./host-connection.js";

interface Harness {
  port: number;
  stop: () => Promise<void>;
}

async function startDaemon(): Promise<Harness> {
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
    },
    pino({ level: "warn" }),
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
});
