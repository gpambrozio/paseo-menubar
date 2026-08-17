import { parseConnectionOfferFromUrl } from "@getpaseo/protocol/connection-offer";
import type { HostEntry } from "./host-config.js";

/**
 * Parses the URL printed by `paseo daemon pair`.
 *
 * Returns null when the input is not a pairing URL at all, which is the common
 * case for arbitrary clipboard contents. Throws when it looks like one but the
 * payload does not validate, because that is a real error worth showing.
 */
export function hostEntryFromPairingUrl(
  input: string,
  options: { id: string; label?: string },
): HostEntry | null {
  const offer = parseConnectionOfferFromUrl(input);
  if (!offer) return null;

  const label = options.label?.trim();
  return {
    id: options.id,
    type: "relay",
    // No serverId fallback baked in here: `label` is optional precisely so
    // an unnamed host falls through to the daemon's live `hostname` (and
    // then to `serverId`) at render time -- see `resolveHostName` in
    // `src/tray/view-model.ts`. Persisting the serverId as a label would
    // pin that forever and the hostname would never get a chance to show.
    ...(label ? { label } : {}),
    // Stored verbatim. The TLS default belongs to the connection layer, not here.
    offer,
  };
}
