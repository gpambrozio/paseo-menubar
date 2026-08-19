import { z } from "zod";
import { DirectTcpHostConnectionSchema } from "@getpaseo/protocol/host-connection-schema";
import { ConnectionOfferSchema } from "@getpaseo/protocol/connection-offer";

// Both host shapes come from the published schemas rather than parallel
// redefinitions, so a protocol change surfaces as a type error here.
//
// `label` is optional on both. It is the user's explicit name for the host,
// and an absent label is what lets the tray fall through to the daemon's own
// `hostname` instead — see `resolveHostName` in `src/tray/view-model.ts` for
// the full precedence. A required field with no "unset" value cannot
// represent that; existing configs that already have a label keep working
// unchanged.
const DirectHostSchema = DirectTcpHostConnectionSchema.extend({
  label: z.string().min(1).optional(),
});

const RelayHostSchema = z.object({
  id: z.string().min(1),
  type: z.literal("relay"),
  label: z.string().min(1).optional(),
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
 * Stable identity of a host list, used to tell a real change in the Paseo
 * app's registry apart from Chromium rewriting its leveldb for keys the tray
 * does not care about.
 *
 * Plain `JSON.stringify` is not stable enough: zod emits keys in schema order
 * while a hand-built entry keeps the order its literal used, so the same host
 * stringifies two ways.
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

/**
 * The last-resort name for a host: the network address the entry itself
 * connects through. Used only when nothing better is known yet — no explicit
 * `label`, and no `hostname` or `serverId` from the daemon, which happens in
 * the sliver of time between an entry being read from config and its first
 * `server_info` message. A direct entry's own endpoint is a stable, sane
 * identifier for that window (e.g. `127.0.0.1:6767`); a relay entry has no
 * daemon-facing address at all before it connects, so the relay's own
 * endpoint stands in.
 */
export function hostEntryEndpointHint(entry: HostEntry): string {
  return entry.type === "directTcp" ? entry.endpoint : entry.offer.relay.endpoint;
}
