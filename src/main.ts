import { app, dialog, shell } from "electron";
import path from "node:path";
import { watch } from "node:fs";
import { HostStore } from "./daemon/host-store.js";
import { createHostFleet } from "./daemon/host-fleet.js";
import { createRegistrySession } from "./registry/registry-session.js";
import { createRegistryWatcher, isRegistryFileEvent } from "./registry/registry-watcher.js";
import { readRegistry, registryLevelDbDir } from "./registry/paseo-registry.js";
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
      const appSupportDir = app.getPath("appData");

      // `session` is reached only from callbacks, all of which run after both
      // consts are initialized: the fleet reports its entry failures to the
      // session, and the session hands loaded host sets back to the fleet.
      const fleet = createHostFleet({
        store,
        onEntryFailures: (failures) => session.noteEntryFailures(failures),
      });

      /**
       * Watches the Paseo app's leveldb directory. Chromium rewrites it
       * constantly for keys we do not care about, so this only signals; the
       * session debounces and decides whether anything actually changed.
       *
       * The directory can be absent (Paseo not installed) or vanish (the app
       * is uninstalled while we run), and the watch itself can die. All the
       * deciding lives in `createRegistryWatcher` and `createRegistrySession`;
       * this supplies `fs.watch` and the one rule that cannot be expressed
       * there — an FSWatcher 'error' event with no listener takes the process
       * down.
       */
      const registryWatcher = createRegistryWatcher({
        resolveDir: () => registryLevelDbDir(appSupportDir),
        open: (dir, { onChange, onError }) => {
          const watcher = watch(dir, (_event, filename) => {
            if (isRegistryFileEvent(filename)) onChange();
          });
          watcher.on("error", () => {
            watcher.close();
            onError();
          });
          return () => watcher.close();
        },
      });

      const session = createRegistrySession({
        readRegistry: () => readRegistry(appSupportDir),
        watch: (onChange) => registryWatcher.watch(onChange),
        afterRead: () => registryWatcher.ensureAttached(),
        applyConfig: (config) => fleet.apply(config),
        onConfigError: (message) => store.setConfigError(message),
      });

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

      app.on("before-quit", () => {
        session.stop();
        presenter.dispose();
        fleet.closeAll();
      });

      await session.start();
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
