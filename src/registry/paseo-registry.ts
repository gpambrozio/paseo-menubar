import { access } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { DirectTcpHostConnectionSchema } from "@getpaseo/protocol/host-connection-schema";
import type { HostEntry } from "../config/host-entry.js";
import { errorText } from "../error-text.js";
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

/**
 * The shipped app's support directory. A development build of the desktop
 * package is deliberately not probed: it loads its window from the dev
 * server rather than `paseo://app`, so its localStorage is keyed under that
 * origin and the record this module looks up would never be found there --
 * a probe that succeeds would only turn "not installed" into a misleading
 * "no hosts yet".
 */
const APP_DIR = "Paseo";
const LOCAL_STORAGE_SUBPATH = path.join("Local Storage", "leveldb");

/**
 * The two connection shapes the tray can actually dial, the two it knows it
 * cannot, and a catch-all for whatever the Paseo app adds next.
 *
 * `directTcp` reuses the published `DirectTcpHostConnectionSchema` rather
 * than redefining the shape locally — the same schema `src/config/host-entry.ts`
 * uses for the app's own config — so a protocol change surfaces as a type
 * error here instead of silently drifting. `relay`, `directSocket`, and
 * `directPipe` have no published equivalent in this SDK version, so those
 * stay hand-rolled. `id` is optional on every shape because the app's own
 * on-disk schema makes it optional and regenerates it on load; the tray only
 * needs it to honour `preferredConnectionId`.
 *
 * The catch-all matters because the desktop app is not version-pinned: it
 * writes this database on its own release cadence, and a connection kind the
 * tray has never heard of must reduce to "this host has no connection the
 * menu bar can use", not to a rejected registry that takes every other host
 * down with it. A *known* kind with a malformed shape is still rejected, at
 * the profile level, so the row can say what was wrong.
 */
const KnownConnectionSchema = z.discriminatedUnion("type", [
  DirectTcpHostConnectionSchema.extend({ id: z.string().optional() }),
  z.object({
    id: z.string().optional(),
    type: z.literal("relay"),
    relayEndpoint: z.string(),
    useTls: z.boolean().optional(),
    daemonPublicKeyB64: z.string(),
  }),
  z.object({ id: z.string().optional(), type: z.literal("directSocket"), path: z.string() }),
  z.object({ id: z.string().optional(), type: z.literal("directPipe"), path: z.string() }),
]);
const KNOWN_CONNECTION_TYPES = new Set(["directTcp", "relay", "directSocket", "directPipe"]);
const UnknownConnectionSchema = z.object({
  id: z.string().optional(),
  // `abort` matters: a non-aborting refine failure makes zod report this
  // branch alone as the union's verdict, hiding the known branch's real
  // complaint ("endpoint: required") behind a bare "Invalid input".
  type: z.string().refine((type) => !KNOWN_CONNECTION_TYPES.has(type), {
    message: "known connection types must match their own schema",
    abort: true,
  }),
});
const RegistryConnectionSchema = z.union([KnownConnectionSchema, UnknownConnectionSchema]);

/**
 * One stored profile. `serverId` is trimmed because the app trims it on
 * load, and the tray sends it verbatim as a relay session id; `label` admits
 * `null` because the app's schema does, and an absent, null, or empty label
 * all mean "no name" downstream.
 */
const HostProfileSchema = z.object({
  serverId: z.string().trim().min(1),
  label: z.string().nullable().optional(),
  connections: z.array(RegistryConnectionSchema),
  preferredConnectionId: z.string().nullable().optional(),
});

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
type DialableConnection = Extract<RegistryConnection, { type: "directTcp" | "relay" }>;
type HostProfile = z.infer<typeof HostProfileSchema>;

function isDialable(connection: RegistryConnection): connection is DialableConnection {
  return connection.type === "directTcp" || connection.type === "relay";
}

/**
 * Picks the connection to dial: the profile's preference when the tray
 * supports it, else the first supported one. A profile can name a preference
 * the tray cannot use (a unix socket) while still carrying a usable relay, and
 * dropping that host would lose a working connection for no reason.
 */
function chooseConnection(profile: HostProfile): DialableConnection | null {
  const supported = profile.connections.filter(isDialable);
  const preferred = supported.find((connection) => connection.id === profile.preferredConnectionId);
  return preferred ?? supported[0] ?? null;
}

/**
 * The best name for a profile that may not have parsed: its label if it has
 * one, its serverId if it has one, else its position. Empty strings do not
 * count as names, or the failure row would open with a bare dash.
 */
function describeProfile(candidate: unknown, index: number): string {
  if (typeof candidate === "object" && candidate !== null) {
    const { label, serverId } = candidate as { label?: unknown; serverId?: unknown };
    if (typeof label === "string" && label.trim() !== "") return label;
    if (typeof serverId === "string" && serverId.trim() !== "") return serverId;
  }
  return `profile ${index + 1}`;
}

/**
 * Flattens a profile's issues into "path: message" lines. A connection that
 * matches no branch of the union reports as one `invalid_union` issue whose
 * detail sits a level down, and that detail -- "endpoint: required" -- is
 * the part the row needs.
 */
function describeIssues(issues: z.core.$ZodIssue[]): string[] {
  return issues.flatMap((issue) => {
    if (issue.code === "invalid_union") return issue.errors.flatMap(describeIssues);
    return [`${issue.path.map(String).join(".") || "profile"}: ${issue.message}`];
  });
}

export function hostEntriesFromRegistry(json: string): RegistrySnapshot {
  const parsed: unknown = JSON.parse(json);
  // Anything but an array means the record is not the registry we know how
  // to read at all, so that is a whole-read failure. One profile that does
  // not parse is not: every other host is still exactly as usable as before,
  // and losing them over a sibling is the silent cap this project forbids.
  const candidates = z.array(z.unknown()).parse(parsed);

  const hosts: HostEntry[] = [];
  const failures: string[] = [];
  const seenServerIds = new Set<string>();

  for (const [index, candidate] of candidates.entries()) {
    const name = describeProfile(candidate, index);
    const result = HostProfileSchema.safeParse(candidate);
    if (!result.success) {
      failures.push(`${name} — could not be read (${describeIssues(result.error.issues).join("; ")})`);
      continue;
    }
    const profile = result.data;

    const connection = chooseConnection(profile);
    if (!connection) {
      const kinds = profile.connections.map((entry) => entry.type);
      const has = kinds.length > 0 ? ` (has: ${kinds.join(", ")})` : "";
      failures.push(`${name} — no connection the menu bar can use${has}`);
      continue;
    }

    // Two profiles for one daemon is a shape the Paseo app can hold, and the
    // id keys the fleet's connection map: the second entry would overwrite
    // the first, leaving one live socket wearing the other's label, type, and
    // web base url. The first profile wins and the second is named, because
    // dropping it quietly is the silent cap this project forbids.
    if (seenServerIds.has(profile.serverId)) {
      failures.push(
        `${name} — a second profile for host ${profile.serverId}; the menu bar shows the first`,
      );
      continue;
    }
    seenServerIds.add(profile.serverId);

    // The id is the serverId, never the connection id: distinct hosts share
    // the identical connection id `relay:wss:relay.paseo.sh:443`, which the
    // duplicate-id check rejects outright. serverId is unique per daemon and
    // stable across restarts, which also keeps the derived clientId stable so
    // the daemon resumes sessions instead of starting new ones.
    //
    // `HostEntrySchema` requires a label to be non-empty when present, so an
    // empty or null one is left out rather than carried through.
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
 * The leveldb directory of the installed Paseo app.
 *
 * Throws when it is absent: that is a distinct, actionable state ("the app
 * is not installed") rather than an empty registry, and the tray says so.
 * Any other reason the directory cannot be reached -- a permission change, a
 * file sitting where the directory should be -- is a different problem with
 * a different fix, so it is reported with its own error rather than folded
 * into "not found".
 */
export async function registryLevelDbDir(appSupportDir: string): Promise<string> {
  const dir = path.join(appSupportDir, APP_DIR, LOCAL_STORAGE_SUBPATH);
  try {
    await access(dir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`Paseo desktop app not found.\n\nLooked in:\n${dir}`);
    }
    throw new Error(`Could not open the Paseo app's storage at ${dir}: ${errorText(error)}`, {
      cause: error,
    });
  }
  return dir;
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
