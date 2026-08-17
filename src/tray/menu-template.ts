import type { MenuItemConstructorOptions } from "electron";
import type { HostStatus } from "../daemon/agent-store.js";
import type { TrayAgentRow, TrayMenuSection, TrayViewModel } from "./view-model.js";

export interface MenuHandlers {
  onOpenAgent: (row: TrayAgentRow) => void;
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
    items.push({ label: `…and ${section.overflow} more`, enabled: false });
  }
  return items;
}

export function buildMenuTemplate(
  model: TrayViewModel,
  handlers: MenuHandlers,
  options: { loginItemEnabled: boolean },
): MenuItemConstructorOptions[] {
  const items: MenuItemConstructorOptions[] = [];

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
      items.push({ label: `${host.label} · ${STATUS_TEXT[host.status]}`, enabled: false });
    }
  }

  // Every action lives in the menu. AppIndicator desktops swallow left-click,
  // so nothing may be click-only.
  items.push(
    { type: "separator" },
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
