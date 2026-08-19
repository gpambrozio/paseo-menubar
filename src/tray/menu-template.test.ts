import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MenuItemConstructorOptions } from "electron";
import type { WorkspaceStateBucket } from "@getpaseo/protocol/messages";
import type { TrayViewModel, TrayWorkspaceRow } from "./view-model.js";
import { buildMenuTemplate } from "./menu-template.js";

/** A predictable, non-filesystem stand-in for tray-presenter's real resolver. */
const iconFor = vi.fn((bucket: WorkspaceStateBucket) => `icon:${bucket}`);

function menuOptions(overrides: { loginItemEnabled?: boolean } = {}) {
  return { loginItemEnabled: false, iconFor, ...overrides };
}

/** Invokes a menu item's handler; the real signature's arguments are unused. */
function click(item: MenuItemConstructorOptions | undefined): void {
  (item?.click as (() => void) | undefined)?.();
}

const handlers = {
  onOpenWorkspace: vi.fn(),
  onOpenApp: vi.fn(),
  onRetryHost: vi.fn(),
  onToggleLoginItem: vi.fn(),
  onQuit: vi.fn(),
};

beforeEach(() => {
  for (const handler of Object.values(handlers)) handler.mockClear();
  iconFor.mockClear();
});

const empty: TrayViewModel = {
  icon: "done",
  count: 0,
  sections: [],
  hostStatuses: [],
  truncatedHosts: [],
  agentIndexTruncatedHosts: [],
  configError: null,
};

function row(overrides: Partial<TrayWorkspaceRow> = {}): TrayWorkspaceRow {
  return {
    hostId: "h1",
    serverId: "srv-1",
    workspaceId: "w1",
    agentId: "a1",
    label: "fix-login",
    projectName: "paseo",
    hostLabel: null,
    ...overrides,
  };
}

describe("buildMenuTemplate", () => {
  it("shows an explicit empty state", () => {
    const labels = buildMenuTemplate(empty, handlers, menuOptions()).map(
      (i) => i.label,
    );
    expect(labels).toContain("No workspaces");
  });

  it("labels sections with Paseo's own words", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        { bucket: "needs_input", rows: [row()], overflow: 0 },
        { bucket: "failed", rows: [row({ workspaceId: "w2" })], overflow: 0 },
        { bucket: "attention", rows: [row({ workspaceId: "w3" })], overflow: 0 },
        { bucket: "running", rows: [row({ workspaceId: "w4" })], overflow: 0 },
        { bucket: "done", rows: [row({ workspaceId: "w5" })], overflow: 0 },
      ],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());
    const headings = template.filter((i) => i.enabled === false).map((i) => i.label);
    expect(headings).toEqual([
      "Needs input",
      "Failed",
      "Ready to review",
      "Working",
      "Done",
    ]);
    // Flat, in order, no submenus anywhere.
    expect(template.every((item) => item.submenu === undefined)).toBe(true);
  });

  it("gives each section heading its bucket's icon, resolved through the injected iconFor", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        { bucket: "needs_input", rows: [row()], overflow: 0 },
        { bucket: "done", rows: [row({ workspaceId: "w2" })], overflow: 0 },
      ],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());

    const needsInputHeading = template.find((i) => i.label === "Needs input");
    const doneHeading = template.find((i) => i.label === "Done");
    // Each heading carries its own bucket's icon, not a shared or swapped one --
    // asserting a fixed literal here would pass even if the wiring pointed both
    // headings at the same bucket, so the check goes through the resolver.
    expect(needsInputHeading?.icon).toBe(iconFor("needs_input"));
    expect(doneHeading?.icon).toBe(iconFor("done"));
    expect(needsInputHeading?.icon).not.toBe(doneHeading?.icon);
    expect(iconFor).toHaveBeenCalledWith("needs_input");
    expect(iconFor).toHaveBeenCalledWith("done");

    // Rows are workspaces, not sections -- only the heading gets a bucket icon.
    const row1 = template.find((i) => i.label?.includes("fix-login"));
    expect(row1?.icon).toBeUndefined();
  });

  it("rules between sections, but never above the first one", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        { bucket: "needs_input", rows: [row()], overflow: 0 },
        { bucket: "running", rows: [row({ workspaceId: "w2" })], overflow: 0 },
        { bucket: "done", rows: [row({ workspaceId: "w3" })], overflow: 0 },
      ],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());
    // Shape down to the first host-status separator: heading, row, rule,
    // heading, row, rule, heading, row. A leading rule would show up as a
    // separator in position 0.
    const shape = template
      .slice(0, 8)
      .map((i) => (i.type === "separator" ? "---" : (i.label ?? "?")));
    expect(shape).toEqual([
      "Needs input",
      "fix-login  ·  paseo",
      "---",
      "Working",
      "fix-login  ·  paseo",
      "---",
      "Done",
      "fix-login  ·  paseo",
    ]);
  });

  it("draws no rule when only one section has anything in it", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [{ bucket: "done", rows: [row()], overflow: 0 }],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());
    // The trailing separator before the footer is still expected; what must not
    // appear is one bracketing the single section.
    expect(template[0]?.type).not.toBe("separator");
    expect(template[1]?.type).not.toBe("separator");
  });

  it("renders a workspace row with its project and host, and opens it on click", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [
        {
          bucket: "needs_input",
          rows: [row({ hostLabel: "laptop" })],
          overflow: 0,
        },
      ],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());
    const item = template.find((i) => i.label?.includes("fix-login"));
    expect(item?.label).toBe("fix-login  ·  paseo  ·  laptop");
    click(item);
    expect(handlers.onOpenWorkspace).toHaveBeenCalledWith(
      expect.objectContaining({ workspaceId: "w1", agentId: "a1" }),
    );
  });

  it("renders the overflow row rather than dropping rows silently, and it opens the app", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [{ bucket: "needs_input", rows: [], overflow: 3 }],
    };
    const template = buildMenuTemplate(model, handlers, menuOptions());
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
    const template = buildMenuTemplate(model, handlers, menuOptions());

    const connected = template.find((item) => item.label === "laptop · connected");
    expect(connected?.enabled).toBe(false);

    const failed = template.find((item) => item.label?.startsWith("studio · authentication failed"));
    expect(failed?.label).toBe("studio · authentication failed — retry");
    expect(failed?.enabled).not.toBe(false);
    click(failed);
    expect(handlers.onRetryHost).toHaveBeenCalledWith("h2");
  });

  it("surfaces a configuration error as a row carrying the message as a tooltip", () => {
    const model: TrayViewModel = { ...empty, configError: "registry error\n\nnot valid JSON" };
    const template = buildMenuTemplate(model, handlers, menuOptions());
    const row = template.find((item) => item.label === "Configuration error");
    expect(row).toBeDefined();
    expect(row?.toolTip).toContain("not valid JSON");
  });

  it("opens the Paseo app from the configuration error row", () => {
    const template = buildMenuTemplate(
      { ...empty, configError: "something is wrong" },
      handlers,
      menuOptions(),
    );
    click(template.find((item) => item.label === "Configuration error"));
    expect(handlers.onOpenApp).toHaveBeenCalledTimes(1);
  });

  it("names the invalid-entry status so a bad host is visible, not missing", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [{ hostId: "h1", label: "my server", status: "invalid" }],
    };
    const labels = buildMenuTemplate(model, handlers, menuOptions()).map(
      (i) => i.label,
    );
    expect(labels).toContain("my server · invalid configuration");
  });

  it("names a host whose workspace list was capped", () => {
    const model: TrayViewModel = { ...empty, truncatedHosts: ["laptop"] };
    const labels = buildMenuTemplate(model, handlers, menuOptions()).map(
      (i) => i.label,
    );
    expect(labels).toContain("Not all workspaces shown · laptop");
  });

  it("names a host whose agent page was capped, because clicks may miss their target", () => {
    const model: TrayViewModel = { ...empty, agentIndexTruncatedHosts: ["laptop"] };
    const labels = buildMenuTemplate(model, handlers, menuOptions()).map(
      (i) => i.label,
    );
    expect(labels).toContain("Not all agents loaded · laptop");
  });

  it("shows a host status line per host", () => {
    const model: TrayViewModel = {
      ...empty,
      hostStatuses: [
        { hostId: "h1", label: "laptop", status: "connected" },
        { hostId: "h2", label: "studio", status: "unauthorized" },
      ],
    };
    const labels = buildMenuTemplate(model, handlers, menuOptions()).map(
      (i) => i.label,
    );
    expect(labels).toContain("laptop · connected");
    expect(labels).toContain("studio · authentication failed — retry");
  });

  it("always offers the footer actions, because AppIndicator swallows left-click", () => {
    const template = buildMenuTemplate(empty, handlers, menuOptions({ loginItemEnabled: true }));
    expect(template.map((i) => i.label)).toEqual(
      expect.arrayContaining(["Open Paseo", "Start at login", "Quit"]),
    );

    // Without this the app is only reachable through a workspace row, so an
    // idle fleet has no way in at all.
    click(template.find((item) => item.label === "Open Paseo"));
    expect(handlers.onOpenApp).toHaveBeenCalledTimes(1);
  });
});
