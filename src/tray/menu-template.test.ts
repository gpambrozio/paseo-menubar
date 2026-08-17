import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MenuItemConstructorOptions } from "electron";
import type { TrayViewModel } from "./view-model.js";
import { buildMenuTemplate } from "./menu-template.js";

/** Invokes a menu item's handler; the real signature's arguments are unused. */
function click(item: MenuItemConstructorOptions | undefined): void {
  (item?.click as (() => void) | undefined)?.();
}

const handlers = {
  onOpenAgent: vi.fn(),
  onOpenApp: vi.fn(),
  onRetryHost: vi.fn(),
  onAddHostFromClipboard: vi.fn(),
  onEditConfig: vi.fn(),
  onToggleLoginItem: vi.fn(),
  onQuit: vi.fn(),
};

beforeEach(() => {
  for (const handler of Object.values(handlers)) handler.mockClear();
});

const empty: TrayViewModel = {
  icon: "idle",
  count: 0,
  sections: [],
  hostStatuses: [],
  truncatedHosts: [],
  configError: null,
};

describe("buildMenuTemplate", () => {
  it("shows an explicit empty state", () => {
    const labels = buildMenuTemplate(empty, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("No agents");
  });

  it("renders attention rows with their reason", () => {
    const model: TrayViewModel = {
      icon: "attention",
      count: 1,
      sections: [
        {
          kind: "attention",
          rows: [
            {
              hostId: "h1",
              serverId: "srv-1",
              agentId: "a1",
              label: "Fix login",
              detail: "permission",
              hostLabel: null,
            },
          ],
          overflow: 0,
        },
      ],
      hostStatuses: [{ hostId: "h1", label: "laptop", status: "connected" }],
      truncatedHosts: [],
      configError: null,
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("Needs you");
    expect(labels.some((label) => label?.includes("Fix login") && label.includes("permission"))).toBe(true);
  });

  it("renders the overflow row rather than dropping rows silently, and it opens the app", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [{ kind: "attention", rows: [], overflow: 3 }],
    };
    const template = buildMenuTemplate(model, handlers, { loginItemEnabled: false });
    const overflow = template.find((item) => item.label === "…and 3 more");
    expect(overflow?.enabled).not.toBe(false);
    click(overflow);
    expect(handlers.onOpenApp).toHaveBeenCalledTimes(1);
  });

  it("offers a retry on an unauthorized host, whose client stopped reconnecting", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [
        { hostId: "h1", label: "laptop", status: "connected" },
        { hostId: "h2", label: "studio", status: "unauthorized" },
      ],
    };
    const template = buildMenuTemplate(model, handlers, { loginItemEnabled: false });

    const connected = template.find((item) => item.label === "laptop · connected");
    expect(connected?.enabled).toBe(false);

    const failed = template.find((item) => item.label?.startsWith("studio · authentication failed"));
    expect(failed?.label).toBe("studio · authentication failed — retry");
    expect(failed?.enabled).not.toBe(false);
    click(failed);
    expect(handlers.onRetryHost).toHaveBeenCalledWith("h2");
  });

  it("surfaces a configuration error as a row that opens the file", () => {
    const model: TrayViewModel = { ...empty, configError: "config.json\n\nnot valid JSON" };
    const template = buildMenuTemplate(model, handlers, { loginItemEnabled: false });
    const row = template.find((item) => item.label === "Configuration error");
    expect(row).toBeDefined();
    expect(row?.toolTip).toContain("not valid JSON");
    click(row);
    expect(handlers.onEditConfig).toHaveBeenCalledTimes(1);
  });

  it("names the invalid-entry status so a bad host is visible, not missing", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [{ hostId: "h1", label: "my server", status: "invalid" }],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("my server · invalid configuration");
  });

  it("names a host whose agent list was capped", () => {
    const model: TrayViewModel = { ...empty, truncatedHosts: ["laptop"] };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("Not all agents shown · laptop");
  });

  it("puts idle agents in a submenu labelled with their count", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        {
          kind: "idle",
          rows: [
            { hostId: "h1", serverId: "srv-1", agentId: "a1", label: "one", detail: null, hostLabel: null },
            { hostId: "h1", serverId: "srv-1", agentId: "a2", label: "two", detail: null, hostLabel: null },
          ],
          overflow: 0,
        },
      ],
    };
    const template = buildMenuTemplate(model, handlers, { loginItemEnabled: false });
    const idle = template.find((item) => item.label === "Idle (2)");
    expect(idle?.submenu).toHaveLength(2);
  });

  it("shows a host status line per host", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [
        { hostId: "h1", label: "laptop", status: "connected" },
        { hostId: "h2", label: "studio", status: "unauthorized" },
      ],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("laptop · connected");
    expect(labels).toContain("studio · authentication failed — retry");
  });

  it("always offers the footer actions, because AppIndicator swallows left-click", () => {
    const template = buildMenuTemplate(empty, handlers, { loginItemEnabled: true });
    expect(template.map((i) => i.label)).toEqual(
      expect.arrayContaining([
        "Open Paseo",
        "Add host from clipboard…",
        "Edit configuration…",
        "Start at login",
        "Quit",
      ]),
    );

    // Without this the app is only reachable through an agent row, so an idle
    // fleet has no way in at all.
    click(template.find((item) => item.label === "Open Paseo"));
    expect(handlers.onOpenApp).toHaveBeenCalledTimes(1);
  });
});
