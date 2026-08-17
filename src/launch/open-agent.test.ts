import { describe, expect, it, vi } from "vitest";
import { defaultDesktopAppInstalled, openAgent, openApp } from "./open-agent.js";

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
