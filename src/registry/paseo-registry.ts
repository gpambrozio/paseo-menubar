import { access } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { DirectTcpHostConnectionSchema } from "@getpaseo/protocol/host-connection-schema";
import type { HostEntry } from "../config/host-entry.js";
import { decodeLocalStorageValue, localStorageKey } from "./local-storage.js";
import { readLevelDbValue } from "./leveldb-reader.js";

/**
 * Reads the Paseo desktop app's host registry out of its Chromium
 * localStorage.
 *
 * This is an unsupported surface: the app persists the registry through
 * async-storage, which on Electron is plain localStorage, and nothing upstream
 * promises the location, the key, or the value encoding. The payload's *shape*
 * is safe, because it is the published protocol schemas; the way we reach it
 * is not. See docs/superpowers/2026-08-19-registry-sync-design.md.
 */

const ORIGIN = "paseo://app";
const REGISTRY_KEY = "@paseo:daemon-registry";
const LOCAL_STORAGE_SUBPATH = path.join("Local Storage", "leveldb");

/**
 * Candidate application-support directory names, in priority order. The
 * shipped app is `Paseo`; a development build of the desktop package uses the
 * scoped package name instead.
 */
const APP_DIR_CANDIDATES = ["Paseo", "@getpaseo/desktop"];

/**
 * Only the two connection shapes the tray can actually dial. `directSocket`
 * and `directPipe` are parsed so a host carrying one is recognised and
 * reported, rather than silently vanishing.
 *
 * `directTcp` reuses the published `DirectTcpHostConnectionSchema` rather
 * than redefining the shape locally — the same schema `src/config/host-entry.ts`
 * uses for the app's own config — so a protocol change surfaces as a type
 * error here instead of silently drifting. `relay`, `directSocket`, and
 * `directPipe` have no published equivalent in this SDK version, so those
 * stay hand-rolled.
 */
const RegistryConnectionSchema = z.discriminatedUnion("type", [
  DirectTcpHostConnectionSchema,
  z.object({
    id: z.string(),
    type: z.literal("relay"),
    relayEndpoint: z.string(),
    useTls: z.boolean().optional(),
    daemonPublicKeyB64: z.string(),
  }),
  z.object({ id: z.string(), type: z.literal("directSocket"), path: z.string() }),
  z.object({ id: z.string(), type: z.literal("directPipe"), path: z.string() }),
]);

const HostProfileSchema = z.object({
  serverId: z.string().min(1),
  label: z.string().optional(),
  connections: z.array(RegistryConnectionSchema),
  preferredConnectionId: z.string().nullable().optional(),
});

const RegistrySchema = z.array(HostProfileSchema);

export interface RegistrySnapshot {
  hosts: HostEntry[];
  /** Hosts the tray cannot dial, phrased for the error row. Never silent. */
  failures: string[];
  /**
   * Set when the hosts above were read out of a database that was partly
   * unreadable, so they may be superseded. The hosts are still applied — a
   * healthy file's answer beats no answer — but the row has to say so, or a
   * host the user deleted in the Paseo app stays in the tray looking healthy.
   */
  warning?: string;
}

type RegistryConnection = z.infer<typeof RegistryConnectionSchema>;

function isSupported(
  connection: RegistryConnection,
): connection is Extract<RegistryConnection, { type: "directTcp" | "relay" }> {
  return connection.type === "directTcp" || connection.type === "relay";
}

/**
 * Picks the connection to dial: the profile's preference when the tray
 * supports it, else the first supported one. A profile can name a preference
 * the tray cannot use (a unix socket) while still carrying a usable relay, and
 * dropping that host would lose a working connection for no reason.
 */
function chooseConnection(
  profile: z.infer<typeof HostProfileSchema>,
): Extract<RegistryConnection, { type: "directTcp" | "relay" }> | null {
  const supported = profile.connections.filter(isSupported);
  const preferred = supported.find((connection) => connection.id === profile.preferredConnectionId);
  return preferred ?? supported[0] ?? null;
}

export function hostEntriesFromRegistry(json: string): RegistrySnapshot {
  const parsed: unknown = JSON.parse(json);
  const profiles = RegistrySchema.parse(parsed);

  const hosts: HostEntry[] = [];
  const failures: string[] = [];

  for (const profile of profiles) {
    const connection = chooseConnection(profile);
    const name = profile.label ?? profile.serverId;
    if (!connection) {
      failures.push(`${name} — no connection the menu bar can use`);
      continue;
    }

    // The id is the serverId, never the connection id: distinct hosts share
    // the identical connection id `relay:wss:relay.paseo.sh:443`, which the
    // duplicate-id check rejects outright. serverId is unique per daemon and
    // stable across restarts, which also keeps the derived clientId stable so
    // the daemon resumes sessions instead of starting new ones.
    const base = { id: profile.serverId, ...(profile.label ? { label: profile.label } : {}) };

    if (connection.type === "directTcp") {
      hosts.push({
        ...base,
        type: "directTcp",
        endpoint: connection.endpoint,
        // `DirectTcpHostConnectionSchema` declares `useTls` with
        // `.default(false)`, so the parsed output is already a plain
        // boolean — no fallback needed here.
        useTls: connection.useTls,
        ...(connection.password !== undefined ? { password: connection.password } : {}),
      });
    } else {
      hosts.push({
        ...base,
        type: "relay",
        offer: {
          v: 2,
          serverId: profile.serverId,
          daemonPublicKeyB64: connection.daemonPublicKeyB64,
          relay: {
            endpoint: connection.relayEndpoint,
            ...(connection.useTls === undefined ? {} : { useTls: connection.useTls }),
          },
        },
      });
    }
  }

  return { hosts, failures };
}

/**
 * The leveldb directory of whichever Paseo build is installed.
 *
 * Throws when none is present: that is a distinct, actionable state ("the app
 * is not installed") rather than an empty registry, and the tray says so.
 */
export async function registryLevelDbDir(appSupportDir: string): Promise<string> {
  const probed: string[] = [];
  for (const candidate of APP_DIR_CANDIDATES) {
    const dir = path.join(appSupportDir, candidate, LOCAL_STORAGE_SUBPATH);
    probed.push(dir);
    try {
      await access(dir);
      return dir;
    } catch {
      continue;
    }
  }
  throw new Error(`Paseo desktop app not found.\n\nLooked in:\n${probed.join("\n")}`);
}

/** `null` means the app is installed but has never stored a registry. */
export async function readRegistry(appSupportDir: string): Promise<RegistrySnapshot | null> {
  const dir = await registryLevelDbDir(appSupportDir);
  const read = await readLevelDbValue(dir, localStorageKey(ORIGIN, REGISTRY_KEY));
  if (read.value === null) return null;
  const snapshot = hostEntriesFromRegistry(decodeLocalStorageValue(read.value));
  // A value found next to an unreadable file is usable but not trustworthy as
  // the last word; the caller applies it and shows the detail.
  return read.parseFailure === null ? snapshot : { ...snapshot, warning: read.parseFailure };
}
