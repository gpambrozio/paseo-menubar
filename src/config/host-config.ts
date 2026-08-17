import { readFile, writeFile, chmod, rename, unlink } from "node:fs/promises";
import { watch } from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { z } from "zod";
import { DirectTcpHostConnectionSchema } from "@getpaseo/protocol/host-connection-schema";
import { ConnectionOfferSchema } from "@getpaseo/protocol/connection-offer";

// Both host shapes come from the published schemas rather than parallel
// redefinitions, so a protocol change surfaces as a type error here.
const DirectHostSchema = DirectTcpHostConnectionSchema.extend({
  label: z.string().min(1),
});

const RelayHostSchema = z.object({
  id: z.string().min(1),
  type: z.literal("relay"),
  label: z.string().min(1),
  /** The pairing offer, stored exactly as `paseo daemon pair` issued it. */
  offer: ConnectionOfferSchema,
});

export const HostEntrySchema = z.discriminatedUnion("type", [DirectHostSchema, RelayHostSchema]);
export type HostEntry = z.infer<typeof HostEntrySchema>;

export const AppConfigSchema = z
  .object({
    version: z.literal(1),
    hosts: z.array(HostEntrySchema),
  })
  // Ids key the connection map, so a duplicate would silently leak: one entry
  // overwrites the other, leaving an orphaned connection whose socket and
  // subscription never stop, and two clients sharing a clientId. Copying a
  // host block and forgetting to change the id is the most likely hand-edit,
  // so it is rejected with a message that says what happened.
  .superRefine((config, ctx) => {
    const seen = new Set<string>();
    for (const [index, host] of config.hosts.entries()) {
      if (seen.has(host.id)) {
        ctx.addIssue({
          code: "custom",
          path: ["hosts", index, "id"],
          message: `Duplicate host id "${host.id}". Each host needs its own id.`,
        });
      }
      seen.add(host.id);
    }
  });
export type AppConfig = z.infer<typeof AppConfigSchema>;

/**
 * Stable identity of a host list, used to tell the app's own config writes
 * apart from real edits.
 *
 * Plain `JSON.stringify` is not stable enough: zod emits keys in schema order
 * while a hand-built entry keeps the order its literal used, so the same host
 * stringifies two ways. On a fresh install that made the first-run seed look
 * like a change, and the watcher tore down the connection it had just built.
 */
export function hostsFingerprint(hosts: HostEntry[]): string {
  return JSON.stringify(hosts, (_key, value) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).sort(([a], [b]) =>
        a < b ? -1 : a > b ? 1 : 0,
      ),
    );
  });
}

export function configPath(dir: string): string {
  return path.join(dir, "config.json");
}

export async function loadConfig(dir: string): Promise<AppConfig> {
  let raw: string;
  try {
    raw = await readFile(configPath(dir), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return { version: 1, hosts: [] };
    }
    throw error;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid config at ${configPath(dir)}: not valid JSON`, { cause: error });
  }

  const result = AppConfigSchema.safeParse(parsed);
  if (!result.success) {
    throw new Error(`Invalid config at ${configPath(dir)}: ${result.error.message}`);
  }
  return result.data;
}

export async function saveConfig(dir: string, config: AppConfig): Promise<void> {
  const target = configPath(dir);
  // Write to a temp file in the same directory and rename over the target.
  // `mode` on writeFile only applies when a file is newly created, so a
  // plain overwrite of a pre-existing looser-permission file would briefly
  // truncate it at the old mode; and truncate-then-write is not atomic, so a
  // concurrent reader (e.g. our own watchConfig callback) could observe a
  // torn file, which loadConfig would then throw on. The temp-file + rename
  // dance avoids both: the file is 0600 before it is ever visible at
  // `target`, and rename is atomic on POSIX.
  const tmp = path.join(dir, `.config.json.${process.pid}-${crypto.randomBytes(6).toString("hex")}.tmp`);
  try {
    await writeFile(tmp, `${JSON.stringify(config, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    await chmod(tmp, 0o600);
    await rename(tmp, target);
  } catch (error) {
    // Best-effort cleanup so a failed save doesn't leave temp-file debris in
    // the config directory. The original error is what the caller needs, so
    // a failing unlink (e.g. the write itself never created the file) is
    // swallowed rather than allowed to mask it.
    await unlink(tmp).catch(() => {});
    throw error;
  }
}

const WATCH_DEBOUNCE_MS = 250;

/**
 * Calls `onChange` after the config file settles. Editors and our own writes
 * both produce bursts of events, so a debounce is required, not a nicety.
 */
export function watchConfig(dir: string, onChange: () => void): () => void {
  let timer: NodeJS.Timeout | null = null;
  const watcher = watch(dir, (_event, filename) => {
    if (filename && filename !== "config.json") return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      onChange();
    }, WATCH_DEBOUNCE_MS);
  });

  // FSWatcher is an EventEmitter; an unhandled 'error' event throws and takes
  // the whole process down. This is reachable in practice — the watched
  // directory can become inaccessible or be removed out from under us (an
  // external volume unmounts, the user deletes the config dir) — and this is
  // a background menu-bar app, so it must never crash from that. There is no
  // logger yet, so the error is swallowed rather than reported.
  watcher.on("error", () => {});

  return () => {
    if (timer) clearTimeout(timer);
    watcher.close();
  };
}
