import { Menu, Tray, nativeImage } from "electron";
import os from "node:os";
import path from "node:path";
import type { WorkspaceStateBucket } from "@getpaseo/protocol/messages";
import type { HostStore } from "../daemon/host-store.js";
import { buildMenuTemplate, type MenuHandlers } from "./menu-template.js";
import { deriveTrayViewModel, ICON_FILE_PREFIXES, type TrayIconState } from "./view-model.js";

const REBUILD_DEBOUNCE_MS = 120;

/** macOS 14 Sonoma, the first release with native menu section headings. */
const MIN_DARWIN_MAJOR_FOR_HEADER_ITEMS = 23;

/**
 * Electron's `type: "header"` needs macOS 14. Darwin's major version is the
 * reliable check: Darwin 23 is macOS 14, 24 is 15, and so on.
 */
function supportsHeaderItems(): boolean {
  if (process.platform !== "darwin") return false;
  const major = Number.parseInt(os.release().split(".")[0] ?? "", 10);
  return Number.isFinite(major) && major >= MIN_DARWIN_MAJOR_FOR_HEADER_ITEMS;
}

export interface TrayPresenter {
  dispose(): void;
}

export function createTrayPresenter(options: {
  store: HostStore;
  assetsDir: string;
  handlers: MenuHandlers;
  isLoginItemEnabled: () => boolean;
}): TrayPresenter {
  const { store, assetsDir, handlers, isLoginItemEnabled } = options;
  // The OS does not change under a running app, so this is resolved once.
  const headerItemsSupported = supportsHeaderItems();

  function iconPath(bucket: WorkspaceStateBucket): string {
    return path.join(assetsDir, `${ICON_FILE_PREFIXES[bucket]}Template.png`);
  }

  function loadIcon(bucket: WorkspaceStateBucket): Electron.NativeImage {
    const file = iconPath(bucket);
    const image = nativeImage.createFromPath(file);
    // A missing file yields an empty image rather than an error, and an empty
    // image yields a status item with no visible icon -- no way to open the
    // menu, no way to quit. The icons are generated, not committed, so this is
    // reachable from a build that skipped `npm run icons`.
    if (image.isEmpty()) throw new Error(`Missing tray icon: ${file}`);
    return image;
  }

  const icons: Record<TrayIconState, Electron.NativeImage> = {
    needs_input: loadIcon("needs_input"),
    failed: loadIcon("failed"),
    attention: loadIcon("attention"),
    running: loadIcon("running"),
    done: loadIcon("done"),
  };
  for (const image of Object.values(icons)) image.setTemplateImage(true);

  const tray = new Tray(icons.done);
  let timer: NodeJS.Timeout | null = null;

  function render(): void {
    const model = deriveTrayViewModel(store.snapshot(), { configError: store.getConfigError() });
    tray.setImage(icons[model.icon]);
    // No platform supports a numeric badge on a tray icon. macOS gets the count
    // as adjacent text; elsewhere it rides the tooltip.
    if (process.platform === "darwin") {
      tray.setTitle(model.count > 0 ? String(model.count) : "");
    }
    tray.setToolTip(model.count > 0 ? `Paseo — ${model.count} need you` : "Paseo");
    tray.setContextMenu(
      Menu.buildFromTemplate(
        buildMenuTemplate(model, handlers, {
          loginItemEnabled: isLoginItemEnabled(),
          iconFor: iconPath,
          supportsHeaderItems: headerItemsSupported,
        }),
      ),
    );
  }

  const unsubscribe = store.subscribe(() => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      render();
    }, REBUILD_DEBOUNCE_MS);
  });

  render();

  return {
    dispose() {
      if (timer) clearTimeout(timer);
      unsubscribe();
      tray.destroy();
    },
  };
}
