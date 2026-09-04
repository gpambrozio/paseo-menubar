import type { MenuItemConstructorOptions } from "electron";
import type { WorkspaceStateBucket } from "@getpaseo/protocol/messages";
import type { HostStatus } from "../daemon/host-store.js";
import {
  SECTION_LABELS,
  type TrayMenuSection,
  type TrayViewModel,
  type TrayWorkspaceRow,
} from "./view-model.js";

/**
 * Resolves a bucket to its icon, as a path or a `NativeImage`. Injected by
 * `tray-presenter.ts`, the module that knows `assetsDir` — this file stays
 * pure and never touches the filesystem or loads a `NativeImage` itself.
 */
export type IconResolver = (bucket: WorkspaceStateBucket) => Electron.MenuItemConstructorOptions["icon"];

export interface MenuHandlers {
  onOpenWorkspace: (row: TrayWorkspaceRow) => void;
  onOpenApp: () => void;
  /** Rebuilds one host's connection after its auth was fixed on the daemon. */
  onRetryHost: (hostId: string) => void;
  onToggleLoginItem: (enabled: boolean) => void;
  onQuit: () => void;
}

const STATUS_TEXT: Record<HostStatus, string> = {
  connecting: "connecting",
  connected: "connected",
  disconnected: "disconnected",
  unauthorized: "authentication failed",
  invalid: "invalid configuration",
};

function rowLabel(row: TrayWorkspaceRow): string {
  const parts = [row.label, row.projectName];
  if (row.hostLabel) parts.push(row.hostLabel);
  return parts.join("  ·  ");
}

function rowItem(row: TrayWorkspaceRow, handlers: MenuHandlers): MenuItemConstructorOptions {
  return { label: rowLabel(row), click: () => handlers.onOpenWorkspace(row) };
}

/**
 * A disabled heading, then the section's rows. No submenus: the sidebar puts
 * every bucket at the same level, and a submenu would hide one section behind a
 * hover the other four do not need.
 *
 * The heading carries the bucket's icon, matching the sidebar, which shows a
 * glyph per section.
 */
function sectionItems(
  section: TrayMenuSection,
  handlers: MenuHandlers,
  iconFor: IconResolver,
): MenuItemConstructorOptions[] {
  const items: MenuItemConstructorOptions[] = [
    { label: SECTION_LABELS[section.bucket], enabled: false, icon: iconFor(section.bucket) },
    ...section.rows.map((row) => rowItem(row, handlers)),
  ];
  if (section.overflow > 0) {
    // The capped rows are only reachable in the app, so the row goes there.
    items.push({ label: `…and ${section.overflow} more`, click: () => handlers.onOpenApp() });
  }
  return items;
}

export function buildMenuTemplate(
  model: TrayViewModel,
  handlers: MenuHandlers,
  options: { loginItemEnabled: boolean; iconFor: IconResolver },
): MenuItemConstructorOptions[] {
  const items: MenuItemConstructorOptions[] = [];

  if (model.configError) {
    // The fix for every one of these is in the Paseo app, so the row opens it.
    items.push(
      {
        label: "Configuration error",
        toolTip: model.configError,
        click: () => handlers.onOpenApp(),
      },
      { type: "separator" },
    );
  }

  if (model.sections.length === 0) {
    items.push({ label: "No workspaces", enabled: false });
  } else {
    // A rule between sections, not before the first: AppKit draws a leading
    // separator as a stray line under the menu's top edge. The heading already
    // opens each section, so the rule only has to close the one above it.
    model.sections.forEach((section, index) => {
      if (index > 0) items.push({ type: "separator" });
      items.push(...sectionItems(section, handlers, options.iconFor));
    });
  }

  // The seed page has a ceiling. Reaching it means these rows are a subset, and
  // a subset presented as the whole list is the silent cap the spec forbids.
  for (const label of model.truncatedHosts) {
    items.push({ label: `Not all workspaces shown · ${label}`, enabled: false });
  }
  // A capped agent page costs click targets rather than rows: a workspace whose
  // agents fell off the page opens in the browser instead of the app.
  for (const label of model.agentIndexTruncatedHosts) {
    items.push({ label: `Not all agents loaded · ${label}`, enabled: false });
  }

  if (model.hostStatuses.length > 0) {
    items.push({ type: "separator" });
    for (const host of model.hostStatuses) {
      const text = `${host.label} · ${STATUS_TEXT[host.status]}`;
      if (host.status === "unauthorized") {
        // Auth rejection ends the reconnect loop for good, so without this the
        // only way back after fixing the password is relaunching the app.
        items.push({ label: `${text} — retry`, click: () => handlers.onRetryHost(host.hostId) });
      } else {
        items.push({ label: text, enabled: false });
      }
    }
  }

  // Every action lives in the menu. AppIndicator desktops swallow left-click,
  // so nothing may be click-only.
  items.push(
    { type: "separator" },
    { label: "Open Paseo", click: () => handlers.onOpenApp() },
    {
      label: "Start at login",
      type: "checkbox",
      checked: options.loginItemEnabled,
      click: () => handlers.onToggleLoginItem(!options.loginItemEnabled),
    },
    { type: "separator" },
    { label: "Quit", click: () => handlers.onQuit() },
  );

  return items;
}
