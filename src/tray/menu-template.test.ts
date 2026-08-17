import { describe, expect, it, vi } from "vitest";
import type { TrayViewModel } from "./view-model.js";
import { buildMenuTemplate } from "./menu-template.js";

const handlers = {
  onOpenAgent: vi.fn(),
  onAddHostFromClipboard: vi.fn(),
  onEditConfig: vi.fn(),
  onToggleLoginItem: vi.fn(),
  onQuit: vi.fn(),
};

const empty: TrayViewModel = { icon: "idle", count: 0, sections: [], hostStatuses: [] };

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
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("Needs you");
    expect(labels.some((label) => label?.includes("Fix login") && label.includes("permission"))).toBe(true);
  });

  it("renders the overflow row rather than dropping rows silently", () => {
    const model: TrayViewModel = {
      ...empty,
      sections: [{ kind: "attention", rows: [], overflow: 3 }],
    };
    const labels = buildMenuTemplate(model, handlers, { loginItemEnabled: false }).map((i) => i.label);
    expect(labels).toContain("…and 3 more");
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
    expect(labels).toContain("studio · authentication failed");
  });

  it("always offers the footer actions, because AppIndicator swallows left-click", () => {
    const labels = buildMenuTemplate(empty, handlers, { loginItemEnabled: true }).map((i) => i.label);
    expect(labels).toEqual(
      expect.arrayContaining([
        "Add host from clipboard…",
        "Edit configuration…",
        "Start at login",
        "Quit",
      ]),
    );
  });
});
