import { hostsFingerprint, type AppConfig, type HostEntry } from "../config/host-config.js";
import { errorText } from "../error-text.js";
import type { RegistrySnapshot } from "./paseo-registry.js";

export interface RegistrySession {
  /** Reads once and applies. Never rejects. */
  start(): Promise<void>;
  /** Re-reads. Never rejects. Exposed for the watcher, the poll, and tests. */
  refresh(): Promise<void>;
  /** The fleet's unusable entries, for the half of the error row it owns. */
  noteEntryFailures(failures: string[]): void;
  stop(): void;
}

const NO_HOSTS_MESSAGE = "No hosts yet. Pair a host in the Paseo app.";

/**
 * Owns the tray's view of the Paseo app's host registry: when to re-read it,
 * whether anything changed, and what the error row says.
 *
 * Electron-free on purpose, the same way `host-fleet.ts` is. Everything here
 * is reachable on a machine where the Paseo app is missing, mid-write, or has
 * moved its storage, so it has to be testable without a main process.
 *
 * Nothing here may reject. A menu-bar app that dies on a torn read of another
 * program's database leaves the user nothing to fix it with.
 */
export function createRegistrySession(options: {
  /** Injected so tests need no filesystem. Production passes `readRegistry`. */
  readRegistry: () => Promise<RegistrySnapshot | null>;
  /** Starts watching; returns the stop function. Production watches the dir. */
  watch: (onChange: () => void) => () => void;
  applyConfig: (config: AppConfig) => Promise<void>;
  onConfigError: (message: string | null) => void;
  /** Safety net for events the watcher misses. Zero disables it. */
  pollMs?: number;
  debounceMs?: number;
}): RegistrySession {
  const { readRegistry, watch, applyConfig, onConfigError } = options;
  const pollMs = options.pollMs ?? 60_000;
  const debounceMs = options.debounceMs ?? 500;

  let appliedFingerprint: string | null = null;
  let stopWatching: (() => void) | null = null;
  let debounceTimer: NodeJS.Timeout | null = null;
  let pollTimer: NodeJS.Timeout | null = null;
  let running: Promise<void> | null = null;

  // Two independent problems, reported through one menu row: reading the
  // registry, and entries the fleet could not use. Either can be fixed without
  // the other, so neither may clear the other.
  let registryError: string | null = null;
  let fleetError: string | null = null;

  function refreshConfigError(): void {
    const problems = [registryError, fleetError].filter((problem) => problem !== null);
    onConfigError(problems.length > 0 ? problems.join("\n\n") : null);
  }

  async function readAndApply(): Promise<void> {
    let snapshot: RegistrySnapshot | null;
    try {
      snapshot = await readRegistry();
    } catch (error) {
      // Keep the last known-good host set live and say what went wrong. A
      // compaction mid-read lands here and resolves itself on the next tick.
      registryError = errorText(error);
      refreshConfigError();
      return;
    }

    const hosts: HostEntry[] = snapshot?.hosts ?? [];
    const failures = snapshot?.failures ?? [];

    const problems: string[] = [];
    if (snapshot === null) problems.push(NO_HOSTS_MESSAGE);
    if (failures.length > 0) {
      problems.push(`These hosts could not be used:\n\n${failures.join("\n")}`);
    }
    registryError = problems.length > 0 ? problems.join("\n\n") : null;
    refreshConfigError();

    // Rebuilding tears down live connections, so it happens only when the
    // host set genuinely differs -- Chromium rewrites this database constantly
    // for keys we do not care about.
    const fingerprint = hostsFingerprint(hosts);
    if (fingerprint === appliedFingerprint) return;
    appliedFingerprint = fingerprint;
    await applyConfig({ version: 1, hosts });
  }

  /** Serializes reads so a watcher burst cannot interleave two applies. */
  function serialize(): Promise<void> {
    const next = (running ?? Promise.resolve()).then(readAndApply, readAndApply);
    running = next.catch(() => undefined);
    return next;
  }

  async function safeRefresh(): Promise<void> {
    try {
      await serialize();
    } catch (error) {
      // serialize() already routes read failures to the error row; this is the
      // last line against applyConfig throwing.
      registryError = errorText(error);
      refreshConfigError();
    }
  }

  return {
    async start() {
      stopWatching = watch(() => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
          debounceTimer = null;
          void safeRefresh();
        }, debounceMs);
      });
      if (pollMs > 0) {
        pollTimer = setInterval(() => void safeRefresh(), pollMs);
        // A background poll must never hold the process open on its own.
        pollTimer.unref?.();
      }
      await safeRefresh();
    },

    refresh() {
      return safeRefresh();
    },

    noteEntryFailures(failures) {
      fleetError =
        failures.length > 0 ? `These hosts could not be used:\n\n${failures.join("\n")}` : null;
      refreshConfigError();
    },

    stop() {
      if (debounceTimer) clearTimeout(debounceTimer);
      if (pollTimer) clearInterval(pollTimer);
      debounceTimer = null;
      pollTimer = null;
      stopWatching?.();
      stopWatching = null;
    },
  };
}
