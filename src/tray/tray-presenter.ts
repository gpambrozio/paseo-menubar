import { Menu, Tray, nativeImage } from "electron";
import path from "node:path";
import type { AgentStore } from "../daemon/agent-store.js";
import { buildMenuTemplate, type MenuHandlers } from "./menu-template.js";
import { deriveTrayViewModel, type TrayIconState } from "./view-model.js";

const REBUILD_DEBOUNCE_MS = 120;

export interface TrayPresenter {
  dispose(): void;
}

export function createTrayPresenter(options: {
  store: AgentStore;
  assetsDir: string;
  handlers: MenuHandlers;
  isLoginItemEnabled: () => boolean;
}): TrayPresenter {
  const { store, assetsDir, handlers, isLoginItemEnabled } = options;

  const icons: Record<TrayIconState, Electron.NativeImage> = {
    idle: nativeImage.createFromPath(path.join(assetsDir, "idleTemplate.png")),
    working: nativeImage.createFromPath(path.join(assetsDir, "workingTemplate.png")),
    attention: nativeImage.createFromPath(path.join(assetsDir, "attentionTemplate.png")),
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
