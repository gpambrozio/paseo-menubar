import {
  hostEntryEndpointHint,
  hostsFingerprint,
  type AppConfig,
  type HostEntry,
} from "../config/host-config.js";
import type { HostStore } from "./host-store.js";
import { createHostConnection, type HostConnection } from "./host-connection.js";
import { errorText } from "../error-text.js";

export interface HostFleet {
  /**
   * Rebuilds the fleet to match `config`. No-ops when the host list is
   * unchanged. Runs serialized against every other fleet mutation.
   */
  apply(config: AppConfig): Promise<void>;
  /** Rebuilds one host. Serialized alongside `apply`. */
  retry(hostId: string): Promise<void>;
  /** The base URL of the host's own web UI, when it has one. */
  webBaseUrlFor(hostId: string): string | undefined;
  /**
   * The web UI of the first host that is actually `connected`, in config
   * order — the fallback used to open Paseo when the desktop app is not
   * installed. Skips any other status (`connecting`, `disconnected`,
   * `unauthorized`, `invalid`): each of those still yields a defined URL
   * from `webBaseUrlForEntry`, which would suppress `openAgent`'s
   * `paseo://` deep-link fallback — the one that produces an actionable
   * "install the Paseo desktop app" dialog — in favor of a browser tab that
   * cannot load.
   */
  firstWebBaseUrl(): string | undefined;
  /** Fire-and-forget teardown for app shutdown. */
  closeAll(): void;
}

/**
 * Owns the set of live host connections and the config generation they were
 * built from.
 *
 * Electron-free on purpose: this is where the connection bookkeeping that can
 * actually go wrong lives, so it has to be testable without a main process.
 * Anything that needs Electron — reporting the failures, opening the URLs — is
 * the caller's job.
 */
export function createHostFleet(options: {
  store: HostStore;
  /**
   * Receives the entries that could not be used, empty when all are fine.
   * The fleet does not own the wording of the user-facing message: the caller
   * merges this with its other configuration problems.
   */
  onEntryFailures: (failures: string[]) => void;
  /**
   * Test seam. Production builds a real connection per entry; tests supply a
   * fake so fleet behaviour is exercised without a daemon.
   */
  createConnection?: (options: { entry: HostEntry; store: HostStore }) => HostConnection;
}): HostFleet {
  const { store, onEntryFailures } = options;
  const createConnection = options.createConnection ?? createHostConnection;

  const connections = new Map<string, HostConnection>();
  /**
   * The entries behind the live connections. Kept because a `TrayWorkspaceRow`
   * carries only a `hostId`, and both the web fallback and the per-host retry
   * need the entry itself.
   */
  const appliedHosts = new Map<string, HostEntry>();
  /**
   * The unusable entries behind the caller's error row, keyed by entry id so a
   * retry can clear or replace its own without disturbing the other hosts'.
   * Ordered by insertion, which for a rebuild is config order.
   */
  const entryFailures = new Map<string, string>();
  let appliedFingerprint = "";
  let pending: Promise<void> = Promise.resolve();

  /**
   * Rebuilds the connection fleet. Our own writes trip the config watcher, so
   * this no-ops when the host list is unchanged rather than churning sockets.
   */
  async function applyHosts(config: AppConfig): Promise<void> {
    const fingerprint = hostsFingerprint(config.hosts);
    if (fingerprint === appliedFingerprint) return;
    // Recorded only once the fleet is actually built. Claiming it up front
    // meant a rebuild that died partway still looked applied, so a watcher
    // reload could never repair it.
    appliedFingerprint = "";

    for (const connection of connections.values()) await connection.close();
    connections.clear();
    appliedHosts.clear();
    entryFailures.clear();

    for (const entry of config.hosts) {
      appliedHosts.set(entry.id, entry);
      connectHost(entry);
    }

    appliedFingerprint = fingerprint;
    reportEntryFailures();
  }

  function reportEntryFailures(): void {
    onEntryFailures([...entryFailures.values()]);
  }

  /**
   * The daemon serves the web UI on the same endpoint it serves the socket
   * on, so a direct host doubles as the fallback target when the desktop app
   * is not installed. A relay host has no such URL — the relay is a socket
   * tunnel, not an HTTP origin — so it has no fallback.
   */
  function webBaseUrlForEntry(entry: HostEntry): string | undefined {
    if (entry.type !== "directTcp") return undefined;
    return `${entry.useTls ? "https" : "http"}://${entry.endpoint}`;
  }

  /**
   * Creates one host's connection, recording a failure description under
   * `entry.id` when it cannot.
   *
   * Nothing here closes a connection already registered under `entry.id`,
   * because there should never be one: `AppConfigSchema` rejects duplicate ids,
   * `applyHosts` clears the map before rebuilding, and `retry` awaits the old
   * connection's `close()` first. Closing it here is not an option either: that
   * is what the guard which used to sit here did, closing the replaced
   * connection *after* constructing the new one, and `close()`'s tail calls
   * `store.removeHost` on the same id the new connection had just registered —
   * so had it ever fired it would have left a live host the store could no
   * longer see. Closing it *first* would make `connectHost` async, and with it
   * every caller.
   *
   * The invariant is therefore checked rather than repaired: a call site that
   * breaks it gets an unusable host and a named configuration error, instead of
   * a live connection that `connections.set` overwrote and nothing can close.
   */
  function connectHost(entry: HostEntry): void {
    try {
      if (connections.has(entry.id)) {
        throw new Error(`a connection for host id "${entry.id}" already exists`);
      }
      connections.set(entry.id, createConnection({ entry, store }));
      entryFailures.delete(entry.id);
    } catch (error) {
      // One unusable entry — a hand-edited endpoint that cannot form a URL,
      // say — must not take down every host after it. Show it as a host that
      // exists and cannot be used, and name it in the error.
      //
      // The duplicate-id guard above throws into this same catch, and on
      // that path `entry.id` already belongs to the first, live connection —
      // so these two calls relabel *that* host and drop its status to
      // `invalid` until its own status callback flips it back. Unreachable
      // in practice, per the guard's own comment, and nothing leaks, but
      // worth naming so the next reader does not have to re-derive it.
      const endpointHint = hostEntryEndpointHint(entry);
      store.setHost(entry.id, { label: entry.label, endpointHint });
      store.setStatus(entry.id, "invalid");
      // Named the same way `resolveHostName`'s last resort is: an unlabeled
      // entry has no live daemon data to fall back to either, since it never
      // connected, so the entry's own endpoint is the best identifier left.
      entryFailures.set(entry.id, `${entry.label ?? endpointHint}: ${errorText(error)}`);
    }
  }

  /**
   * Rebuilds one host. Auth rejection disposes its client for good, so without
   * this a password fixed on the daemon side has no recovery path short of
   * relaunching — a reload cannot help, since the config bytes never changed.
   *
   * A rebuild that fails reports through the same error row a failure during
   * `applyHosts` does: the tray already shows the host as `invalid`, and
   * without this the row never says which host or why.
   */
  async function retryHost(hostId: string): Promise<void> {
    const entry = appliedHosts.get(hostId);
    if (!entry) return;
    const existing = connections.get(hostId);
    connections.delete(hostId);
    if (existing) await existing.close();
    connectHost(entry);
    reportEntryFailures();
  }

  /**
   * Runs fleet mutations one at a time. They await every `close()`, a window
   * far longer than the watcher's debounce, so two overlapping calls would
   * interleave over the one connection map: each closes what the other just
   * built, and a rebuild can finish with `appliedHosts` describing one
   * generation and the live sockets belonging to another. `host-fleet.test.ts`
   * pins the event order both ways round.
   */
  function serialize(task: () => Promise<void>): Promise<void> {
    const next = pending.then(task);
    pending = next.catch(() => undefined);
    return next;
  }

  return {
    apply(config) {
      return serialize(() => applyHosts(config));
    },
    retry(hostId) {
      return serialize(() => retryHost(hostId));
    },
    webBaseUrlFor(hostId) {
      const entry = appliedHosts.get(hostId);
      return entry ? webBaseUrlForEntry(entry) : undefined;
    },
    firstWebBaseUrl() {
      // `connections.has(hostId)` only tells us a client was built; it stays
      // true through `connecting`, `disconnected`, and `unauthorized` too.
      // `status` is what actually tracks whether the daemon has answered, so
      // it is the only check this needs.
      const statuses = new Map(store.snapshot().map((host) => [host.hostId, host.status]));
      for (const [hostId, entry] of appliedHosts) {
        if (statuses.get(hostId) !== "connected") continue;
        const url = webBaseUrlForEntry(entry);
        if (url !== undefined) return url;
      }
      return undefined;
    },
    closeAll() {
      for (const connection of connections.values()) void connection.close();
    },
  };
}
