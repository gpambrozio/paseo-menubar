import { describe, expect, it } from "vitest";
import { hostEntryFromPairingUrl } from "./pairing.js";

function offerUrl(payload: unknown): string {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `https://app.paseo.sh/#offer=${encoded}`;
}

const validOffer = {
  v: 2,
  serverId: "srv-2",
  daemonPublicKeyB64: "AAAA",
  relay: { endpoint: "relay.paseo.sh:443", useTls: true },
};

describe("hostEntryFromPairingUrl", () => {
  it("builds a relay host entry from a pairing URL", () => {
    expect(hostEntryFromPairingUrl(offerUrl(validOffer), { id: "h2", label: "studio" })).toEqual({
      id: "h2",
      type: "relay",
      label: "studio",
      offer: {
        v: 2,
        serverId: "srv-2",
        daemonPublicKeyB64: "AAAA",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("leaves the label absent when none is given, rather than inventing one from the serverId", () => {
    const entry = hostEntryFromPairingUrl(offerUrl(validOffer), { id: "h2" });
    expect(entry?.label).toBeUndefined();
    // Not just the label key: the whole entry must not carry a baked-in name,
    // since that would permanently outrank the daemon's live hostname.
    expect(entry).toEqual({
      id: "h2",
      type: "relay",
      offer: {
        v: 2,
        serverId: "srv-2",
        daemonPublicKeyB64: "AAAA",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("also leaves the label absent when the given label is blank", () => {
    const entry = hostEntryFromPairingUrl(offerUrl(validOffer), { id: "h2", label: "   " });
    expect(entry?.label).toBeUndefined();
  });

  it("stores the offer verbatim, leaving an omitted useTls absent", () => {
    const entry = hostEntryFromPairingUrl(
      offerUrl({ ...validOffer, relay: { endpoint: "relay.paseo.sh:443" } }),
      { id: "h2" },
    );
    expect(entry).toMatchObject({ offer: { relay: { endpoint: "relay.paseo.sh:443" } } });
    expect(entry?.type === "relay" && entry.offer.relay.useTls).toBeUndefined();
  });

  it("returns null when the text has no offer fragment", () => {
    expect(hostEntryFromPairingUrl("https://app.paseo.sh/", { id: "h2" })).toBeNull();
    expect(hostEntryFromPairingUrl("just some clipboard text", { id: "h2" })).toBeNull();
  });

  it("throws when the fragment exists but is malformed", () => {
    expect(() => hostEntryFromPairingUrl("https://app.paseo.sh/#offer=zzzz", { id: "h2" })).toThrow();
  });
});
