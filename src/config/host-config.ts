import { readFile, writeFile, chmod } from "node:fs/promises";
import { watch } from "node:fs";
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

export const AppConfigSchema = z.object({
  version: z.literal(1),
  hosts: z.array(HostEntrySchema),
});
export type AppConfig = z.infer<typeof AppConfigSchema>;

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
  // Passwords and relay keys live here, so the file is owner-only.
  await writeFile(target, `${JSON.stringify(config, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  await chmod(target, 0o600);
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

  return () => {
    if (timer) clearTimeout(timer);
    watcher.close();
  };
}
