import { app, clipboard, dialog, shell } from "electron";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { HostStore } from "./daemon/host-store.js";
import { createHostFleet } from "./daemon/host-fleet.js";
import { configPath, watchConfig } from "./config/host-config.js";
import { createConfigSession } from "./config/config-session.js";
import { hostEntryFromPairingUrl } from "./config/pairing.js";
import { defaultDesktopAppInstalled, openApp, openWorkspace } from "./launch/open-paseo.js";
import { createTrayPresenter, type TrayPresenter } from "./tray/tray-presenter.js";
import type { TrayWorkspaceRow } from "./tray/view-model.js";
import { errorText } from "./error-text.js";

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  const store = new HostStore();

  function showError(title: string, error: unknown): void {
    dialog.showErrorBox(title, errorText(error));
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

  app.whenReady()
    .then(async () => {
      app.dock?.hide();
      const configDir = app.getPath("userData");

      // `session` is reached only from callbacks, all of which run after both
      // consts are initialized: the fleet reports its entry failures to the
      // session, and the session hands loaded configs back to the fleet.
      const fleet = createHostFleet({
        store,
        onEntryFailures: (failures) => session.noteEntryFailures(failures),
      });
      const session = createConfigSession({
        configDir,
        onConfigError: (message) => store.setConfigError(message),
        applyConfig: (config) => fleet.apply(config),
      });

      async function addHostFromClipboard(): Promise<void> {
        const text = clipboard.readText();
        let entry;
        try {
          entry = hostEntryFromPairingUrl(text, { id: randomUUID() });
        } catch (error) {
          dialog.showErrorBox(
            "Paseo Icon",
            `That pairing link is malformed.\n\n${errorText(error)}`,
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

        // Reading and writing the config can both fail on things the user did
        // not do here -- an unparseable config.json, a read-only config
        // directory -- and this runs from a menu click, so an escaping
        // rejection would kill the process rather than surface anywhere.
        try {
          await session.addHost(entry);
        } catch (error) {
          dialog.showErrorBox(
            "Paseo Icon — could not add host",
            `${configPath(configDir)}\n\n${errorText(error)}`,
          );
          return;
        }
        await dialog.showMessageBox({ message: `Added host "${entry.label}".` });
      }

      function handleOpenWorkspace(row: TrayWorkspaceRow): void {
        if (!row.serverId) return;
        const webBaseUrl = fleet.webBaseUrlFor(row.hostId);
        openWorkspace(
          {
            serverId: row.serverId,
            workspaceId: row.workspaceId,
            agentId: row.agentId,
            ...(webBaseUrl ? { webBaseUrl } : {}),
          },
          { desktopAppInstalled: defaultDesktopAppInstalled, openExternal },
        );
      }

      function handleOpenApp(): void {
        openApp(
          { webBaseUrl: fleet.firstWebBaseUrl() },
          { desktopAppInstalled: defaultDesktopAppInstalled, openExternal },
        );
      }

      let presenter: TrayPresenter;
      try {
        presenter = createTrayPresenter({
          store,
          assetsDir: path.join(app.getAppPath(), "assets", "generated"),
          isLoginItemEnabled: () => app.getLoginItemSettings().openAtLogin,
          handlers: {
            onOpenWorkspace: handleOpenWorkspace,
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
        dialog.showErrorBox("Paseo Icon — failed to start", errorText(error));
        app.quit();
        return;
      }

      const stopWatching = watchConfig(configDir, () =>
        void session.reload().catch((error) =>
          showError("Paseo Icon — configuration error", error),
        ),
      );

      app.on("before-quit", () => {
        stopWatching();
        presenter.dispose();
        fleet.closeAll();
      });

      try {
        await session.start();
      } catch (error) {
        // Connecting to configured hosts failed. The tray is already up and
        // keeps running -- a tray showing zero connected hosts is the
        // correct display for this state, not a reason to crash.
        dialog.showErrorBox("Paseo Icon — configuration error", errorText(error));
      }
    })
    .catch((error) => {
      // Safety net: every stage above already catches its own failures, but
      // Node terminates the process on any unhandled rejection, and a
      // background menu-bar app must never die silently.
      dialog.showErrorBox("Paseo Icon — failed to start", errorText(error));
    });

  // No windows exist, so the default quit-on-all-closed behaviour must not apply.
  app.on("window-all-closed", () => undefined);
}
