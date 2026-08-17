import type { MenuItemConstructorOptions } from "electron";
import type { HostStatus } from "../daemon/agent-store.js";
import type { TrayAgentRow, TrayMenuSection, TrayViewModel } from "./view-model.js";

export interface MenuHandlers {
  onOpenAgent: (row: TrayAgentRow) => void;
  onOpenApp: () => void;
  /** Rebuilds one host's connection after its auth was fixed on the daemon. */
  onRetryHost: (hostId: string) => void;
  onAddHostFromClipboard: () => void;
  onEditConfig: () => void;
  onToggleLoginItem: (enabled: boolean) => void;
  onQuit: () => void;
}

const SECTION_TITLES = { attention: "Needs you", working: "Working", idle: "Idle" } as const;

const STATUS_TEXT: Record<HostStatus, string> = {
  connecting: "connecting",
  connected: "connected",
  disconnected: "disconnected",
  unauthorized: "authentication failed",
  invalid: "invalid configuration",
};

const REASON_TEXT: Record<string, string> = {
  finished: "done",
  permission: "permission",
  error: "error",
};

function rowLabel(row: TrayAgentRow): string {
  const parts = [row.label];
  if (row.detail) parts.push(REASON_TEXT[row.detail] ?? row.detail);
  if (row.hostLabel) parts.push(row.hostLabel);
  return parts.join("  ·  ");
}

function rowItem(row: TrayAgentRow, handlers: MenuHandlers): MenuItemConstructorOptions {
  return { label: rowLabel(row), click: () => handlers.onOpenAgent(row) };
}

function sectionItems(
  section: TrayMenuSection,
  handlers: MenuHandlers,
): MenuItemConstructorOptions[] {
  if (section.kind === "idle") {
    return [
      {
        label: `${SECTION_TITLES.idle} (${section.rows.length})`,
        submenu: section.rows.map((row) => rowItem(row, handlers)),
      },
    ];
  }

  const items: MenuItemConstructorOptions[] = [
    { label: SECTION_TITLES[section.kind], enabled: false },
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
  options: { loginItemEnabled: boolean },
): MenuItemConstructorOptions[] {
  const items: MenuItemConstructorOptions[] = [];

  if (model.configError) {
    // First row, and clickable: the fix is in the file, so the row opens it.
    items.push(
      {
        label: "Configuration error",
        toolTip: model.configError,
        click: () => handlers.onEditConfig(),
      },
      { type: "separator" },
    );
  }

  if (model.sections.length === 0) {
    items.push({ label: "No agents", enabled: false });
  } else {
    for (const section of model.sections) items.push(...sectionItems(section, handlers));
  }

  // The seed page has a ceiling. Reaching it means the count is a floor, and
  // a floor presented as a total is the silent cap the spec forbids.
  for (const label of model.truncatedHosts) {
    items.push({ label: `Not all agents shown · ${label}`, enabled: false });
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
    { label: "Add host from clipboard…", click: () => handlers.onAddHostFromClipboard() },
    { label: "Edit configuration…", click: () => handlers.onEditConfig() },
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
