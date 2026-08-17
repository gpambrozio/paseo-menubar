import { app, clipboard, dialog, shell } from "electron";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { AgentStore } from "./daemon/agent-store.js";
import { createHostFleet } from "./daemon/host-fleet.js";
import {
  loadConfig,
  saveConfig,
  configPath,
  watchConfig,
  type AppConfig,
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

  const fleet = createHostFleet({
    store,
    onEntryFailures: (failures) => {
      hostEntryError =
        failures.length > 0
          ? `${configPath(configDir)}\n\nThese hosts could not be used:\n\n${failures.join("\n")}`
          : null;
      refreshConfigError();
    },
  });

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
    await fleet.apply(config);
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

  function handleOpenAgent(row: TrayAgentRow): void {
    if (!row.serverId) return;
    const webBaseUrl = fleet.webBaseUrlFor(row.hostId);
    openAgent(
      { serverId: row.serverId, agentId: row.agentId, ...(webBaseUrl ? { webBaseUrl } : {}) },
      { desktopAppInstalled: defaultDesktopAppInstalled, openExternal },
    );
  }

  function handleOpenApp(): void {
    const webBaseUrl = fleet
      .hostIds()
      .map((hostId) => fleet.webBaseUrlFor(hostId))
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
              void fleet
                .retry(hostId)
                .catch((error) => showError("Paseo Icon — could not reconnect", error)),
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
        fleet.closeAll();
      });

      try {
        await fleet.apply(await ensureConfig());
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
