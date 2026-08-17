import { randomUUID } from "node:crypto";
import { errorText } from "../error-text.js";
import {
  configPath,
  loadConfig,
  saveConfig,
  type AppConfig,
  type HostEntry,
} from "./host-config.js";

const DEFAULT_LOCAL_ENDPOINT = "127.0.0.1:6767";

export interface ConfigSession {
  /**
   * Loads the config and hands it to `applyConfig`, seeding the local daemon
   * on first run. Never rejects on a bad config file: an unusable file is
   * reported and the app comes up with no hosts, because a menu-bar app that
   * dies on startup leaves the user nothing to fix it with.
   */
  start(): Promise<void>;
  /**
   * Re-reads the config after the watcher fired. A file that cannot be read
   * leaves the last known-good state applied and reports the problem.
   */
  reload(): Promise<void>;
  /** Appends a host and saves. The watcher is what applies it. */
  addHost(entry: HostEntry): Promise<void>;
  /** The fleet's unusable entries, for the half of the error row it owns. */
  noteEntryFailures(failures: string[]): void;
}

/**
 * Owns the config file's in-memory state: what is on disk, what is wrong with
 * it, and the first-run seed.
 *
 * Electron-free on purpose, the same way `host-fleet.ts` is. Everything here
 * is reachable from a menu click on a machine whose config directory is
 * read-only or whose `config.json` someone hand-edited, so it has to be
 * testable without a main process. Reading the clipboard, showing the dialogs,
 * and painting the error row are the caller's job.
 */
export function createConfigSession(options: {
  configDir: string;
  /**
   * Receives the single message behind the tray's `Configuration error` row,
   * or null when there is nothing wrong. The session does not own where it is
   * displayed.
   */
  onConfigError: (message: string | null) => void;
  /** Hands a freshly loaded config to whatever owns the connections. */
  applyConfig: (config: AppConfig) => Promise<void>;
  /** Test seam for the id the first-run seed gets. */
  createId?: () => string;
}): ConfigSession {
  const { configDir, onConfigError, applyConfig } = options;
  const createId = options.createId ?? randomUUID;

  // Two independent config problems, reported through one menu row: the file
  // itself is unusable, and individual entries in an otherwise good file are.
  // Either can be fixed without the other, so neither may clear the other.
  let configFileError: string | null = null;
  let hostEntryError: string | null = null;

  function refreshConfigError(): void {
    onConfigError(configFileError ?? hostEntryError);
  }

  /** Every file-level problem names the file, since the fix is to edit it. */
  function describeFileError(error: unknown): string {
    return `${configPath(configDir)}\n\n${errorText(error)}`;
  }

  async function ensureConfig(): Promise<AppConfig> {
    try {
      const config = await loadConfig(configDir);
      if (config.hosts.length > 0) return config;
      // First run: adopt the local daemon so there is nothing to configure.
      const seeded: AppConfig = {
        version: 1,
        hosts: [
          {
            id: createId(),
            label: "This machine",
            type: "directTcp",
            endpoint: DEFAULT_LOCAL_ENDPOINT,
            useTls: false,
          },
        ],
      };
      await saveConfig(configDir, seeded);
      return seeded;
    } catch (error) {
      configFileError = describeFileError(error);
      refreshConfigError();
      // Keep running with no hosts rather than dying; the menu offers a way out.
      return { version: 1, hosts: [] };
    }
  }

  return {
    async start() {
      await applyConfig(await ensureConfig());
    },

    async reload() {
      let config: AppConfig;
      try {
        config = await loadConfig(configDir);
      } catch (error) {
        // The last known-good state keeps running; the menu carries the news.
        configFileError = describeFileError(error);
        refreshConfigError();
        return;
      }
      configFileError = null;
      refreshConfigError();
      await applyConfig(config);
    },

    async addHost(entry) {
      const config = await loadConfig(configDir);
      config.hosts.push(entry);
      // The config watcher is the single reload path; writing is enough.
      await saveConfig(configDir, config);
    },

    noteEntryFailures(failures) {
      hostEntryError =
        failures.length > 0
          ? `${configPath(configDir)}\n\nThese hosts could not be used:\n\n${failures.join("\n")}`
          : null;
      refreshConfigError();
    },
  };
}
