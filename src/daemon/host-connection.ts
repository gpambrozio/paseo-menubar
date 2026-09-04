import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import {
  buildDaemonWebSocketUrl,
  buildRelayWebSocketUrl,
  shouldUseTlsForDefaultHostedRelay,
} from "@getpaseo/protocol/daemon-endpoints";
import { hostEntryEndpointHint, type HostEntry } from "../config/host-entry.js";
import type { HostStore } from "./host-store.js";
import { errorText } from "../error-text.js";

const AGENT_PAGE_LIMIT = 200;
const WORKSPACE_PAGE_LIMIT = 200;
const SEED_RETRY_MS = 2_000;
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
  // "new session" path instead of resuming. `entry.id` is already a stable
  // identifier — the daemon's own `serverId`, sourced from the Paseo app's
  // registry.
  const clientId = `paseo-menubar-${entry.id}`;

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
 * Seeding doubles as the daemon's required handshake — the daemon sends no
 * unsolicited list, and each stream only starts once its own fetch has asked
 * for it, so `agent_update` needs `fetch_agents_request` and `workspace_update`
 * needs `fetch_workspaces_request`.
 */
export function createHostConnection(options: {
  entry: HostEntry;
  store: HostStore;
  /**
   * Test seam. Production builds a real `DaemonClient` from the entry; this
   * keeps the SDK surface in this one module while letting tests drive
   * connection transitions and failing seeds that a real daemon will not
   * produce on demand.
   */
  createClient?: (entry: HostEntry) => DaemonClient;
}): HostConnection {
  const { entry, store } = options;
  // The client is built before the host is registered: `buildClient` throws on
  // an endpoint that cannot form a URL, and registering first would leave a
  // host in the store with no connection that owns it, so nothing could ever
  // remove it. Throwing before `setHost` leaves the caller free to record the
  // failure however it likes.
  const client = (options.createClient ?? buildClient)(entry);
  store.setHost(entry.id, { label: entry.label, endpointHint: hostEntryEndpointHint(entry) });
  let closed = false;
  let seedRetryTimer: ReturnType<typeof setTimeout> | null = null;
  let unsubscribeStatus: (() => void) | null = null;

  const unsubscribeAgents = client.on("agent_update", (message) => {
    const payload = message.payload;
    if (payload.kind === "upsert") {
      store.applyAgentUpdate(entry.id, { kind: "upsert", agent: payload.agent });
    } else if (payload.kind === "remove") {
      store.applyAgentUpdate(entry.id, { kind: "remove", agentId: payload.agentId });
    }
  });

  const unsubscribeWorkspaces = client.on("workspace_update", (message) => {
    const payload = message.payload;
    if (payload.kind === "upsert") {
      store.applyWorkspaceUpdate(entry.id, { kind: "upsert", workspace: payload.workspace });
    } else if (payload.kind === "remove") {
      // The removal field here is `id`. `agent_update`'s is `agentId`, so the
      // two payloads do not have the same shape and copying one onto the other
      // yields `undefined` and a row that never leaves the menu.
      store.applyWorkspaceUpdate(entry.id, { kind: "remove", workspaceId: payload.id });
    }
  });

  async function seed(): Promise<void> {
    // No `scope`. `scope: "active"` narrows harder than the live subscription
    // does -- it also requires a workspaceId with an unarchived workspace and
    // project -- so the stream would be a strict superset of the seed and
    // agents that streamed in would vanish at the next re-seed. Default scope
    // plus the subscription's implicit `includeArchived: false` gives both
    // sides the same rule the spec states: archived agents are excluded.
    const response = await client.fetchAgents({
      // The page limit is a hard ceiling (200, the protocol's max), so on a
      // busy host the sort decides which agents the icon is counted from. The
      // daemon sorts every candidate before it slices to the limit
      // (`@getpaseo/server`'s `listFetchAgentsEntries`), and
      // `status_priority` ranks pending permission 0, error 1, running 2,
      // initializing 3, everything else 4 (`@getpaseo/protocol`'s
      // `getAgentStatusPriority`) — so ascending puts the agents that drive
      // the icon at the front. `updated_at` stays as the tiebreaker, which is
      // the daemon's default sort and so what the rest of the page used to be
      // ordered by.
      sort: [
        { key: "status_priority", direction: "asc" },
        { key: "updated_at", direction: "desc" },
      ],
      page: { limit: AGENT_PAGE_LIMIT },
      subscribe: {},
    });
    // The menu's rows. `status_priority` ascending is the same key the agent
    // fetch uses, so on a host past the page limit the workspaces that drive
    // the icon are the ones that survive the slice. No secondary key: the
    // daemon's own default ordering decides the rest, and inventing one here
    // would be the client-side derivation this design exists to avoid.
    const workspaces = await client.fetchWorkspaces({
      sort: [{ key: "status_priority", direction: "asc" }],
      page: { limit: WORKSPACE_PAGE_LIMIT },
      subscribe: {},
    });
    // Both lists land together, after both fetches resolved. A half-applied
    // seed would pair fresh workspaces with a stale agent index, and the
    // retry path re-runs both anyway.
    //
    // Wholesale replacement: a subscription gap must not strand a dead row.
    store.seedAgents(
      entry.id,
      response.entries.map((item) => item.agent),
      // Caps are visible, never silent: the page limit is a real ceiling and
      // the menu says so rather than quietly undercounting.
      { truncated: response.pageInfo.hasMore },
    );
    store.seedWorkspaces(entry.id, workspaces.entries, {
      truncated: workspaces.pageInfo.hasMore,
    });
    // Both fields ride the same `server_info` message, so they land together.
    // `hostname` is what lets the tray show a real machine name instead of an
    // opaque serverId or the raw connection endpoint — see `resolveHostName`
    // in `src/tray/view-model.ts`.
    const serverInfo = client.getLastServerInfoMessage();
    if (serverInfo) {
      store.setServerId(entry.id, serverInfo.serverId);
      store.setHostname(entry.id, serverInfo.hostname);
    }
    store.setStatus(entry.id, "connected");
  }

  function clearSeedRetry(): void {
    if (seedRetryTimer) {
      clearTimeout(seedRetryTimer);
      seedRetryTimer = null;
    }
  }

  /**
   * Seeds, and keeps trying while the socket stays up.
   *
   * A failed seed leaves a live connection with no agent list, which reports
   * as `disconnected` because the app cannot vouch for agents it never
   * fetched. Nothing else would ever retry: the next status transition is the
   * only other seed trigger, and a healthy socket produces none.
   */
  function requestSeed(): void {
    clearSeedRetry();
    // Deferred so seeding never re-enters the client from inside the client's
    // own connection-state listener.
    queueMicrotask(() => {
      if (closed || client.getConnectionState().status !== "connected") return;
      void seed().catch(() => {
        if (closed) return;
        store.setStatus(entry.id, "disconnected");
        if (client.getConnectionState().status !== "connected") return;
        seedRetryTimer = setTimeout(() => {
          seedRetryTimer = null;
          requestSeed();
        }, SEED_RETRY_MS);
      });
    });
  }

  /**
   * Ends the reconnect loop for good (used once the host is classified
   * unauthorized). A wrong password retried behind backoff forever is the
   * failure mode to avoid, so this stops listening and disposes the client
   * rather than leaving it to keep reconnecting underneath a `disconnected`
   * status. Does not remove the host from the store — it stays visible with
   * `"unauthorized"` until the caller calls `close()` or the menu's retry
   * rebuilds the connection.
   */
  function stopRetrying(): void {
    if (closed) return;
    closed = true;
    clearSeedRetry();
    unsubscribeStatus?.();
    unsubscribeAgents();
    unsubscribeWorkspaces();
    void client.close().catch(() => undefined);
  }

  // `subscribeConnectionStatus` reports every transition the client makes,
  // including the `connecting` leg of an SDK-driven reconnect, so no timer is
  // needed. It also fires once on subscribe with the current state (`idle`
  // before `connect()`), which is why `idle` is ignored -- `setHost` already
  // reports `connecting`.
  unsubscribeStatus = client.subscribeConnectionStatus((state) => {
    if (closed) return;
    switch (state.status) {
      case "connecting":
        store.setStatus(entry.id, "connecting");
        return;
      case "connected":
        requestSeed();
        return;
      case "disconnected":
        clearSeedRetry();
        if (isAuthRejection(state.reason)) {
          store.setStatus(entry.id, "unauthorized");
          stopRetrying();
          return;
        }
        store.setStatus(entry.id, "disconnected");
        return;
      case "disposed":
        clearSeedRetry();
        store.setStatus(entry.id, "disconnected");
        return;
      default:
        return;
    }
  });

  void client.connect().catch((error) => {
    if (closed) return;
    // In practice DaemonClient never rejects `connect()` for an auth failure
    // while reconnect is enabled (the status listener above is where that
    // classification actually happens) — this catch covers genuine connect
    // failures such as a malformed URL or a transport that fails to
    // construct. Classify the same way for consistency in case a future SDK
    // version does reject with the same reason text.
    store.setStatus(entry.id, isAuthRejection(errorText(error)) ? "unauthorized" : "disconnected");
  });

  return {
    async close() {
      closed = true;
      clearSeedRetry();
      unsubscribeStatus?.();
      unsubscribeAgents();
      unsubscribeWorkspaces();
      await client.close().catch(() => undefined);
      store.removeHost(entry.id);
    },
  };
}
