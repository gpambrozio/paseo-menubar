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

/**
 * Exact close reasons the daemon sends on the WebSocket close frame when the
 * password bearer token is missing or wrong
 * (`@getpaseo/server`'s `attachAuthenticatedSocket`, websocket-server.js).
 * `DaemonClient` surfaces this verbatim as `ConnectionState`'s `reason` when
 * `status === "disconnected"` — it never becomes a thrown/rejected error
 * while `reconnect.enabled` is true, so classification has to read the
 * connection state, not a caught exception.
 */
const AUTH_REJECTION_REASONS = new Set(["Password required", "Incorrect password"]);

function isAuthRejection(reason: string | null | undefined): boolean {
  return reason != null && AUTH_REJECTION_REASONS.has(reason);
}

function buildClient(entry: HostEntry): DaemonClient {
  // DaemonClient requires an explicit clientId (unlike the createPaseoClient
  // wrapper, which generates one when omitted). It must be stable across app
  // restarts, not random per connection: the daemon keys live session resume
  // by clientId, so a fresh random id on every launch would always take the
  // "new session" path instead of resuming. `entry.id` is already a stable,
  // per-host UUID persisted in config.json.
  const clientId = `paseo-icon-${entry.id}`;

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
  let timer: ReturnType<typeof setInterval>;

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

  /**
   * Ends the reconnect loop for good (used once the host is classified
   * unauthorized). A wrong password retried behind backoff forever is the
   * failure mode to avoid, so this stops polling and disposes the client
   * rather than leaving it to keep reconnecting underneath a `disconnected`
   * status. Does not remove the host from the store — it stays visible with
   * `"unauthorized"` until the caller explicitly calls `close()`.
   */
  function stopRetrying(): void {
    if (closed) return;
    closed = true;
    clearInterval(timer);
    unsubscribe();
    void client.close().catch(() => undefined);
  }

  void (async () => {
    try {
      await client.connect();
      await seed();
    } catch (error) {
      if (closed) return;
      // In practice DaemonClient never rejects `connect()` for an auth
      // failure while reconnect is enabled (see the poller below, which is
      // where that classification actually happens) — this catch covers
      // genuine connect failures such as a malformed URL or a transport that
      // fails to construct. Classify the same way for consistency in case a
      // future SDK version does reject with the same reason text.
      const message = error instanceof Error ? error.message : String(error);
      store.setStatus(entry.id, isAuthRejection(message) ? "unauthorized" : "disconnected");
    }
  })();

  // DaemonClient exposes no connection-state event, so transitions are polled.
  timer = setInterval(() => {
    if (closed) return;
    const state = client.getConnectionState();
    if (state.status === lastStatus) return;
    const previous = lastStatus;
    lastStatus = state.status;

    if (state.status === "connected" && previous !== null) {
      void seed().catch(() => store.setStatus(entry.id, "disconnected"));
      return;
    }
    if (state.status === "disconnected") {
      if (isAuthRejection(state.reason)) {
        store.setStatus(entry.id, "unauthorized");
        stopRetrying();
        return;
      }
      store.setStatus(entry.id, "disconnected");
      return;
    }
    if (state.status === "disposed") {
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
