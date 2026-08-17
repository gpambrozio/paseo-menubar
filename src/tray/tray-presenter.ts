import { Menu, Tray, nativeImage } from "electron";
import path from "node:path";
import type { HostStore } from "../daemon/host-store.js";
import { buildMenuTemplate, type MenuHandlers } from "./menu-template.js";
import { deriveTrayViewModel, type TrayIconState } from "./view-model.js";

const REBUILD_DEBOUNCE_MS = 120;

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

  function loadIcon(name: string): Electron.NativeImage {
    const file = path.join(assetsDir, `${name}Template.png`);
    const image = nativeImage.createFromPath(file);
    // A missing file yields an empty image rather than an error, and an empty
    // image yields a status item with no visible icon -- no way to open the
    // menu, no way to quit. The icons are generated, not committed, so this is
    // reachable from a build that skipped `npm run icons`.
    if (image.isEmpty()) throw new Error(`Missing tray icon: ${file}`);
    return image;
  }

  const icons: Record<TrayIconState, Electron.NativeImage> = {
    idle: loadIcon("idle"),
    working: loadIcon("working"),
    attention: loadIcon("attention"),
  };
  for (const image of Object.values(icons)) image.setTemplateImage(true);

  const tray = new Tray(icons.idle);
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
        buildMenuTemplate(model, handlers, { loginItemEnabled: isLoginItemEnabled() }),
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
