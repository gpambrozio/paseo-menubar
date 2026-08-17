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

  return {
    id: options.id,
    type: "relay",
    label: options.label?.trim() || offer.serverId,
    // Stored verbatim. The TLS default belongs to the connection layer, not here.
    offer,
  };
}
