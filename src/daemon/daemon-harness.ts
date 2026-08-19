import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { Writable } from "node:stream";
import os from "node:os";
import path from "node:path";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";

interface Harness {
  port: number;
  stop: () => Promise<void>;
}

/**
 * The daemon logs a page of speech-provider reconciliation warnings on every
 * boot, and this suite boots one per test. They go nowhere rather than being
 * silenced at the pino level, so a test that supplies its own logger — the
 * auth-rejection test counts the daemon's rejection lines — still sees
 * everything the daemon emits.
 */
export function createDiscardingLogger(): pino.Logger {
  return pino(
    { level: "warn" },
    new Writable({
      write(_chunk, _encoding, callback) {
        callback();
      },
    }),
  );
}

/**
 * Boots a real `@getpaseo/server` daemon on an OS-assigned port. Not built
 * into `dist` — `@getpaseo/server` is a devDependency, and this module exists
 * only for tests that need a real daemon rather than a fake `DaemonClient`.
 */
export async function startDaemon(options?: {
  auth?: { password: string };
  logger?: pino.Logger;
}): Promise<Harness> {
  const root = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-daemon-"));
  const paseoHome = path.join(root, ".paseo");
  await mkdir(paseoHome, { recursive: true });
  const staticDir = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-static-"));

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
    options?.logger ?? createDiscardingLogger(),
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
