import { app, clipboard, dialog, shell } from "electron";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { AgentStore } from "./daemon/agent-store.js";
import { createHostConnection, type HostConnection } from "./daemon/host-connection.js";
import {
  loadConfig,
  saveConfig,
  configPath,
  watchConfig,
  hostsFingerprint,
  type AppConfig,
  type HostEntry,
} from "./config/host-config.js";
import { hostEntryFromPairingUrl } from "./config/pairing.js";
import { defaultDesktopAppInstalled, openAgent, openApp } from "./launch/open-agent.js";
import { createTrayPresenter, type TrayPresenter } from "./tray/tray-presenter.js";
import type { TrayAgentRow } from "./tray/view-model.js";

const DEFAULT_LOCAL_ENDPOINT = "127.0.0.1:6767";

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  const store = new AgentStore();
  const connections = new Map<string, HostConnection>();
  let configDir = "";

  function errorText(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
  }

  function showError(title: string, error: unknown): void {
    dialog.showErrorBox(title, errorText(error));
  }

  // Two independent config problems, reported through one menu row: the file
  // itself is unusable, and individual entries in an otherwise good file are.
  // Either can be fixed without the other, so neither may clear the other.
  let configFileError: string | null = null;
  let hostEntryError: string | null = null;

  function refreshConfigError(): void {
    store.setConfigError(configFileError ?? hostEntryError);
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
            id: randomUUID(),
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
      configFileError = `${configPath(configDir)}\n\n${errorText(error)}`;
      refreshConfigError();
      // Keep running with no hosts rather than dying; the menu offers a way out.
      return { version: 1, hosts: [] };
    }
  }

  let appliedFingerprint = "";
  let pendingReconnect: Promise<void> = Promise.resolve();
  /**
   * The entries behind the live connections. Kept because a `TrayAgentRow`
   * carries only a `hostId`, and both the web fallback and the per-host retry
   * need the entry itself.
   */
  const appliedHosts = new Map<string, HostEntry>();

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
    hostEntryError =
      failures.length > 0
        ? `${configPath(configDir)}\n\nThese hosts could not be used:\n\n${failures.join("\n")}`
        : null;
    refreshConfigError();
  }

  /** Creates one host's connection. Returns a failure description, or null. */
  function connectHost(entry: HostEntry): string | null {
    try {
      const connection = createHostConnection({ entry, store });
      // Duplicate ids are rejected by the schema; this is the belt to that
      // brace, because silently overwriting one leaks a live connection whose
      // socket and timers nothing can ever reach again.
      const replaced = connections.get(entry.id);
      if (replaced) void replaced.close();
      connections.set(entry.id, connection);
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
   * interleave and one generation's `connections.clear()` would drop the
   * other's live connections without closing them.
   */
  function serialize(task: () => Promise<void>): Promise<void> {
    const next = pendingReconnect.then(task);
    pendingReconnect = next.catch(() => undefined);
    return next;
  }

  function reconnectAll(config: AppConfig): Promise<void> {
    return serialize(() => applyHosts(config));
  }

  async function reloadFromDisk(): Promise<void> {
    let config: AppConfig;
    try {
      config = await loadConfig(configDir);
    } catch (error) {
      // The last known-good fleet keeps running; the menu carries the news.
      configFileError = `${configPath(configDir)}\n\n${errorText(error)}`;
      refreshConfigError();
      return;
    }
    configFileError = null;
    refreshConfigError();
    await reconnectAll(config);
  }

  async function addHostFromClipboard(): Promise<void> {
    const text = clipboard.readText();
    let entry;
    try {
      entry = hostEntryFromPairingUrl(text, { id: randomUUID() });
    } catch (error) {
      dialog.showErrorBox(
        "Paseo Icon",
        `That pairing link is malformed.\n\n${error instanceof Error ? error.message : String(error)}`,
      );
      return;
    }
    if (!entry) {
      dialog.showErrorBox(
        "Paseo Icon",
        "No pairing link on the clipboard.\n\nRun `paseo daemon pair` and copy the link it prints.",
      );
      return;
    }

    // Reading and writing the config can both fail on things the user did not
    // do here -- an unparseable config.json, a read-only config directory --
    // and this runs from a menu click, so an escaping rejection would kill the
    // process rather than surface anywhere.
    try {
      const config = await loadConfig(configDir);
      config.hosts.push(entry);
      // The config watcher is the single reload path; writing is enough.
      await saveConfig(configDir, config);
    } catch (error) {
      dialog.showErrorBox(
        "Paseo Icon — could not add host",
        `${configPath(configDir)}\n\n${errorText(error)}`,
      );
      return;
    }
    await dialog.showMessageBox({ message: `Added host "${entry.label}".` });
  }

  /**
   * `shell.openExternal` returns a promise that rejects when the OS has no
   * handler for the URL, and `paseo:` is registered only by the installed
   * desktop app. Electron's main process follows Node's throw-on-unhandled-
   * rejection default, so discarding that promise turns "Paseo is not
   * installed" into "the tray disappears". Every open goes through here.
   */
  function openExternal(url: string): void {
    shell.openExternal(url).catch((error) => {
      dialog.showErrorBox(
        "Paseo Icon — could not open Paseo",
        `${url}\n\n${errorText(error)}\n\nInstall the Paseo desktop app to open agents from the menu bar.`,
      );
    });
  }

  /**
   * The daemon serves the web UI on the same endpoint it serves the socket
   * on, so a direct host doubles as the fallback target when the desktop app
   * is not installed. A relay host has no such URL — the relay is a socket
   * tunnel, not an HTTP origin — so it has no fallback.
   */
  function webBaseUrlFor(hostId: string): string | undefined {
    const entry = appliedHosts.get(hostId);
    if (!entry || entry.type !== "directTcp") return undefined;
    return `${entry.useTls ? "https" : "http"}://${entry.endpoint}`;
  }

  function handleOpenAgent(row: TrayAgentRow): void {
    if (!row.serverId) return;
    const webBaseUrl = webBaseUrlFor(row.hostId);
    openAgent(
      { serverId: row.serverId, agentId: row.agentId, ...(webBaseUrl ? { webBaseUrl } : {}) },
      { desktopAppInstalled: defaultDesktopAppInstalled, openExternal },
    );
  }

  function handleOpenApp(): void {
    const webBaseUrl = [...appliedHosts.keys()]
      .map((hostId) => webBaseUrlFor(hostId))
      .find((url) => url !== undefined);
    openApp({ webBaseUrl }, { desktopAppInstalled: defaultDesktopAppInstalled, openExternal });
  }

  app.whenReady()
    .then(async () => {
      app.dock?.hide();
      configDir = app.getPath("userData");

      let presenter: TrayPresenter;
      try {
        presenter = createTrayPresenter({
          store,
          assetsDir: path.join(app.getAppPath(), "assets", "generated"),
          isLoginItemEnabled: () => app.getLoginItemSettings().openAtLogin,
          handlers: {
            onOpenAgent: handleOpenAgent,
            onOpenApp: handleOpenApp,
            onRetryHost: (hostId) =>
              void serialize(() => retryHost(hostId)).catch((error) =>
                showError("Paseo Icon — could not reconnect", error),
              ),
            onAddHostFromClipboard: () =>
              void addHostFromClipboard().catch((error) =>
                showError("Paseo Icon — could not add host", error),
              ),
            onEditConfig: () => void shell.openPath(configPath(configDir)),
            onToggleLoginItem: (enabled) => app.setLoginItemSettings({ openAtLogin: enabled }),
            onQuit: () => app.quit(),
          },
        });
      } catch (error) {
        // No tray means no way to see or control the app at all -- there is
        // nothing to fall back to, so surface the failure and exit rather
        // than running invisibly with no indicator and no menu.
        dialog.showErrorBox(
          "Paseo Icon — failed to start",
          error instanceof Error ? error.message : String(error),
        );
        app.quit();
        return;
      }

      const stopWatching = watchConfig(configDir, () =>
        void reloadFromDisk().catch((error) =>
          showError("Paseo Icon — configuration error", error),
        ),
      );

      app.on("before-quit", () => {
        stopWatching();
        presenter.dispose();
        for (const connection of connections.values()) void connection.close();
      });

      try {
        await reconnectAll(await ensureConfig());
      } catch (error) {
        // Connecting to configured hosts failed. The tray is already up and
        // keeps running -- a tray showing zero connected hosts is the
        // correct display for this state, not a reason to crash.
        dialog.showErrorBox(
          "Paseo Icon — configuration error",
          error instanceof Error ? error.message : String(error),
        );
      }
    })
    .catch((error) => {
      // Safety net: every stage above already catches its own failures, but
      // Node terminates the process on any unhandled rejection, and a
      // background menu-bar app must never die silently.
      dialog.showErrorBox(
        "Paseo Icon — failed to start",
        error instanceof Error ? error.message : String(error),
      );
    });

  // No windows exist, so the default quit-on-all-closed behaviour must not apply.
  app.on("window-all-closed", () => undefined);
}
