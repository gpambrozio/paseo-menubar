import crypto from "node:crypto";
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import {
  buildDaemonWebSocketUrl,
  buildRelayWebSocketUrl,
  shouldUseTlsForDefaultHostedRelay,
} from "@getpaseo/protocol/daemon-endpoints";
import type { HostEntry } from "../config/host-config.js";
import type { AgentStore } from "./agent-store.js";

const STATUS_POLL_MS = 1_000;
const AGENT_PAGE_LIMIT = 200;
const APP_VERSION = "0.4.0";

export interface HostConnection {
  close(): Promise<void>;
}

function isUnauthorized(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\b401\b|unauthor|forbidden/i.test(message);
}

function buildClient(entry: HostEntry): DaemonClient {
  // DaemonClient requires an explicit clientId (unlike the createPaseoClient
  // wrapper, which generates one when omitted) — one is minted per connection.
  const clientId = `paseo-icon-${crypto.randomUUID()}`;

  if (entry.type === "relay") {
    const { offer } = entry;
    return new DaemonClient({
      url: buildRelayWebSocketUrl({
        endpoint: offer.relay.endpoint,
        serverId: offer.serverId,
        role: "client",
        // Same default the CLI applies when an offer omits it.
        useTls: offer.relay.useTls ?? shouldUseTlsForDefaultHostedRelay(offer.relay.endpoint),
      }),
      clientId,
      clientType: "cli",
      appVersion: APP_VERSION,
      e2ee: { enabled: true, daemonPublicKeyB64: offer.daemonPublicKeyB64 },
      reconnect: { enabled: true },
    });
  }

  return new DaemonClient({
    url: buildDaemonWebSocketUrl(entry.endpoint, { useTls: entry.useTls }),
    clientId,
    clientType: "cli",
    appVersion: APP_VERSION,
    ...(entry.password ? { password: entry.password } : {}),
    reconnect: { enabled: true },
  });
}

/**
 * Owns one host: connect, seed, subscribe, and keep the store's view of this
 * host's status honest.
 *
 * Seeding doubles as the daemon's required handshake — until a
 * `fetch_agents_request` arrives, other requests hang silently.
 */
export function createHostConnection(options: {
  entry: HostEntry;
  store: AgentStore;
}): HostConnection {
  const { entry, store } = options;
  store.setHost(entry.id, entry.label);

  const client = buildClient(entry);
  let closed = false;
  let lastStatus: string | null = null;

  const unsubscribe = client.on("agent_update", (message) => {
    const payload = message.payload;
    if (payload.kind === "upsert") {
      store.applyUpdate(entry.id, { kind: "upsert", agent: payload.agent });
    } else if (payload.kind === "remove") {
      store.applyUpdate(entry.id, { kind: "remove", agentId: payload.agentId });
    }
  });

  async function seed(): Promise<void> {
    const response = await client.fetchAgents({
      scope: "active",
      page: { limit: AGENT_PAGE_LIMIT },
      subscribe: {},
    });
    // Wholesale replacement: a subscription gap must not strand a dead agent.
    store.seed(
      entry.id,
      response.entries.map((item) => item.agent),
    );
    const serverId = client.getLastServerInfoMessage()?.serverId;
    if (serverId) store.setServerId(entry.id, serverId);
    store.setStatus(entry.id, "connected");
  }

  void (async () => {
    try {
      await client.connect();
      await seed();
    } catch (error) {
      if (closed) return;
      // A wrong password retried behind backoff forever is the failure mode
      // that wastes an afternoon, so stop and say so.
      store.setStatus(entry.id, isUnauthorized(error) ? "unauthorized" : "disconnected");
    }
  })();

  // DaemonClient exposes no connection-state event, so transitions are polled.
  const timer = setInterval(() => {
    if (closed) return;
    const status = client.getConnectionState().status;
    if (status === lastStatus) return;
    const previous = lastStatus;
    lastStatus = status;

    if (status === "connected" && previous !== null) {
      void seed().catch(() => store.setStatus(entry.id, "disconnected"));
      return;
    }
    if (status === "disconnected" || status === "disposed") {
      store.setStatus(entry.id, "disconnected");
    }
  }, STATUS_POLL_MS);

  return {
    async close() {
      closed = true;
      clearInterval(timer);
      unsubscribe();
      await client.close().catch(() => undefined);
      store.removeHost(entry.id);
    },
  };
}
