import { hostsFingerprint, type AppConfig, type HostEntry } from "../config/host-config.js";
import type { AgentStore } from "./agent-store.js";
import { createHostConnection, type HostConnection } from "./host-connection.js";

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
  /** The ids of the entries behind the live connections, in config order. */
  hostIds(): string[];
  /** Fire-and-forget teardown for app shutdown. */
  closeAll(): void;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
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
  store: AgentStore;
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
  createConnection?: (options: { entry: HostEntry; store: AgentStore }) => HostConnection;
}): HostFleet {
  const { store, onEntryFailures } = options;
  const createConnection = options.createConnection ?? createHostConnection;

  const connections = new Map<string, HostConnection>();
  /**
   * The entries behind the live connections. Kept because a `TrayAgentRow`
   * carries only a `hostId`, and both the web fallback and the per-host retry
   * need the entry itself.
   */
  const appliedHosts = new Map<string, HostEntry>();
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

    const failures: string[] = [];
    for (const entry of config.hosts) {
      appliedHosts.set(entry.id, entry);
      const failure = connectHost(entry);
      if (failure) failures.push(failure);
    }

    appliedFingerprint = fingerprint;
    onEntryFailures(failures);
  }

  /**
   * Creates one host's connection. Returns a failure description, or null.
   *
   * Nothing here closes a connection already registered under `entry.id`,
   * because there can never be one: `AppConfigSchema` rejects duplicate ids,
   * `applyHosts` clears the map before rebuilding, and `retry` awaits the old
   * connection's `close()` first. The guard that used to sit here closed the
   * replaced connection *after* constructing the new one, and `close()`'s tail
   * calls `store.removeHost` on the same id the new connection had just
   * registered — so had it ever fired it would have left a live host that the
   * store could no longer see.
   */
  function connectHost(entry: HostEntry): string | null {
    try {
      connections.set(entry.id, createConnection({ entry, store }));
      return null;
    } catch (error) {
      // One unusable entry — a hand-edited endpoint that cannot form a URL,
      // say — must not take down every host after it. Show it as a host that
      // exists and cannot be used, and name it in the error.
      store.setHost(entry.id, entry.label);
      store.setStatus(entry.id, "invalid");
      return `${entry.label}: ${errorText(error)}`;
    }
  }

  /**
   * Rebuilds one host. Auth rejection disposes its client for good, so without
   * this a password fixed on the daemon side has no recovery path short of
   * relaunching — a reload cannot help, since the config bytes never changed.
   */
  async function retryHost(hostId: string): Promise<void> {
    const entry = appliedHosts.get(hostId);
    if (!entry) return;
    const existing = connections.get(hostId);
    connections.delete(hostId);
    if (existing) await existing.close();
    connectHost(entry);
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
    /**
     * The daemon serves the web UI on the same endpoint it serves the socket
     * on, so a direct host doubles as the fallback target when the desktop app
     * is not installed. A relay host has no such URL — the relay is a socket
     * tunnel, not an HTTP origin — so it has no fallback.
     */
    webBaseUrlFor(hostId) {
      const entry = appliedHosts.get(hostId);
      if (!entry || entry.type !== "directTcp") return undefined;
      return `${entry.useTls ? "https" : "http"}://${entry.endpoint}`;
    },
    hostIds() {
      return [...appliedHosts.keys()];
    },
    closeAll() {
      for (const connection of connections.values()) void connection.close();
    },
  };
}
