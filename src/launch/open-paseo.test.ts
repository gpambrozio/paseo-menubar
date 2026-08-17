import { describe, expect, it, vi } from "vitest";
import {
  defaultDesktopAppInstalled,
  openAgent,
  openApp,
  openWorkspace,
} from "./open-paseo.js";

describe("openAgent", () => {
  it("uses the paseo deep link when the desktop app is installed", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1" },
      { desktopAppInstalled: () => true, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo://h/srv-1/agent/a1");
  });

  it("falls back to the daemon web UI when the desktop app is absent", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767" },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767/h/srv-1/agent/a1");
  });

  it("still tries the deep link when no web fallback is known", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv-1", agentId: "a1" },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo://h/srv-1/agent/a1");
  });

  it("percent-encodes ids so an odd serverId cannot break the route", () => {
    const openExternal = vi.fn();
    openAgent(
      { serverId: "srv 1", agentId: "a/1" },
      { desktopAppInstalled: () => true, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo://h/srv%201/agent/a%2F1");
  });

  it("probes real filesystem paths without throwing", () => {
    expect(typeof defaultDesktopAppInstalled()).toBe("boolean");
  });
});

describe("openWorkspace", () => {
  it("opens the workspace's agent, because there is no workspace deep link", () => {
    const openExternal = vi.fn();
    openWorkspace(
      { serverId: "srv-1", workspaceId: "w1", agentId: "a1" },
      { desktopAppInstalled: () => true, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("paseo://h/srv-1/agent/a1");
  });

  it("falls back to the daemon's workspace route when the workspace has no agent", () => {
    const openExternal = vi.fn();
    openWorkspace(
      {
        serverId: "srv-1",
        workspaceId: "w1",
        agentId: null,
        webBaseUrl: "http://127.0.0.1:6767/",
      },
      { desktopAppInstalled: () => true, openExternal },
    );
    // Even with the desktop app installed: `paseo://h/srv-1/workspace/w1`
    // parses as nothing and would open a window on some other screen.
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767/h/srv-1/workspace/w1");
  });

  it("percent-encodes ids in the workspace route", () => {
    const openExternal = vi.fn();
    openWorkspace(
      {
        serverId: "srv 1",
        workspaceId: "w/1",
        agentId: null,
        webBaseUrl: "http://127.0.0.1:6767",
      },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767/h/srv%201/workspace/w%2F1");
  });

  it("opens Paseo itself when there is neither an agent nor a web URL", () => {
    const openExternal = vi.fn();
    openWorkspace(
      { serverId: "srv-1", workspaceId: "w1", agentId: null },
      { desktopAppInstalled: () => true, openExternal },
    );
    // A relay host with no agents. Doing nothing would read as a broken menu.
    expect(openExternal).toHaveBeenCalledWith("paseo://");
  });

  it("uses the agent's web route when the desktop app is absent", () => {
    const openExternal = vi.fn();
    openWorkspace(
      {
        serverId: "srv-1",
        workspaceId: "w1",
        agentId: "a1",
        webBaseUrl: "http://127.0.0.1:6767",
      },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767/h/srv-1/agent/a1");
  });
});

describe("openApp", () => {
  it("opens the app's scheme when the desktop app is installed", () => {
    const openExternal = vi.fn();
    openApp({}, { desktopAppInstalled: () => true, openExternal });
    expect(openExternal).toHaveBeenCalledWith("paseo://");
  });

  it("falls back to the daemon web UI when the desktop app is absent", () => {
    const openExternal = vi.fn();
    openApp(
      { webBaseUrl: "http://127.0.0.1:6767/" },
      { desktopAppInstalled: () => false, openExternal },
    );
    expect(openExternal).toHaveBeenCalledWith("http://127.0.0.1:6767");
  });

  it("still tries the scheme when no web fallback is known", () => {
    const openExternal = vi.fn();
    openApp({}, { desktopAppInstalled: () => false, openExternal });
    expect(openExternal).toHaveBeenCalledWith("paseo://");
  });
});
