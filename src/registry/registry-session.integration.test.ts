import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { HostStore } from "../daemon/host-store.js";
import { createHostFleet } from "../daemon/host-fleet.js";
import { startDaemon } from "../daemon/daemon-harness.js";
import { createRegistrySession } from "./registry-session.js";

let endpoint: string;
let stopDaemon: () => Promise<void>;

beforeAll(async () => {
  const daemon = await startDaemon();
  endpoint = `127.0.0.1:${daemon.port}`;
  stopDaemon = daemon.stop;
});

afterAll(async () => {
  await stopDaemon();
});

describe("registry session against a real daemon", () => {
  it("connects the fleet to a host the registry reports", async () => {
    const store = new HostStore();
    const fleet = createHostFleet({ store, onEntryFailures: () => undefined });
    const session = createRegistrySession({
      readRegistry: async () => ({
        hosts: [{ id: "srv_itest", label: "itest", type: "directTcp", endpoint, useTls: false }],
        failures: [],
      }),
      watch: () => () => undefined,
      applyConfig: (config) => fleet.apply(config),
      onConfigError: () => undefined,
      pollMs: 0,
    });

    await session.start();

    await expect
      .poll(() => store.snapshot().find((host) => host.hostId === "srv_itest")?.status, {
        timeout: 15_000,
      })
      .toBe("connected");

    session.stop();
    fleet.closeAll();
  });
});
