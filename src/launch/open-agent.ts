import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import {
  buildAgentDeepLink,
  buildAgentDeepLinkRoute,
} from "@getpaseo/protocol/agent-deep-link";

export interface OpenAgentTarget {
  serverId: string;
  agentId: string;
  /** Daemon HTTP base URL, used only when the desktop app is not installed. */
  webBaseUrl?: string;
}

export interface OpenAgentDeps {
  desktopAppInstalled: () => boolean;
  openExternal: (url: string) => void;
}

/** Mirrors the install-path probe the Paseo CLI uses for `paseo open`. */
export function defaultDesktopAppInstalled(): boolean {
  const candidates: string[] =
    process.platform === "darwin"
      ? ["/Applications/Paseo.app", path.join(homedir(), "Applications", "Paseo.app")]
      : process.platform === "linux"
        ? ["/usr/bin/Paseo", "/opt/Paseo/Paseo", path.join(homedir(), "Applications", "Paseo.AppImage")]
        : process.env.LOCALAPPDATA
          ? [path.join(process.env.LOCALAPPDATA, "Programs", "Paseo", "Paseo.exe")]
          : [];

  return candidates.some((candidate) => existsSync(candidate));
}

/**
 * The bare app link. macOS activates whichever app handles a scheme when a URL
 * in it is opened, so this brings Paseo forward even though the desktop app's
 * `open-url` handler ignores links it cannot parse as an agent.
 */
const APP_DEEP_LINK = "paseo://";

/** Opens Paseo itself, with the same web fallback rule `openAgent` uses. */
export function openApp(target: { webBaseUrl?: string | undefined }, deps: OpenAgentDeps): void {
  if (!deps.desktopAppInstalled() && target.webBaseUrl) {
    deps.openExternal(target.webBaseUrl.replace(/\/+$/, ""));
    return;
  }
  deps.openExternal(APP_DEEP_LINK);
}

export function openAgent(target: OpenAgentTarget, deps: OpenAgentDeps): void {
  const { serverId, agentId, webBaseUrl } = target;

  if (!deps.desktopAppInstalled() && webBaseUrl) {
    const route = buildAgentDeepLinkRoute({ serverId, agentId });
    deps.openExternal(`${webBaseUrl.replace(/\/+$/, "")}${route}`);
    return;
  }

  deps.openExternal(buildAgentDeepLink({ serverId, agentId }));
}
