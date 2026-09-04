import { describe, expect, it } from "vitest";
import { hostEntryEndpointHint, hostsFingerprint, type HostEntry } from "./host-entry.js";

describe("hostEntryEndpointHint", () => {
  it("uses a direct entry's own connection address", () => {
    const entry: HostEntry = {
      id: "h1",
      type: "directTcp",
      endpoint: "127.0.0.1:6767",
      useTls: false,
    };
    expect(hostEntryEndpointHint(entry)).toBe("127.0.0.1:6767");
  });

  it("uses a relay entry's relay endpoint", () => {
    const entry: HostEntry = {
      id: "h2",
      type: "relay",
      offer: {
        v: 2,
        serverId: "srv-2",
        daemonPublicKeyB64: "AAAA",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    };
    expect(hostEntryEndpointHint(entry)).toBe("relay.paseo.sh:443");
  });
});

describe("hostsFingerprint", () => {
  it("ignores key order, so a round-tripped entry matches a hand-built one", () => {
    const seeded: HostEntry = {
      id: "h1",
      label: "This machine",
      type: "directTcp",
      endpoint: "127.0.0.1:6767",
      useTls: false,
    };
    // Same fields, different literal order -- what schema-order output vs.
    // hand-built order would each produce.
    const reordered: HostEntry = {
      type: "directTcp",
      endpoint: "127.0.0.1:6767",
      useTls: false,
      id: "h1",
      label: "This machine",
    };

    expect(JSON.stringify([reordered])).not.toBe(JSON.stringify([seeded]));
    expect(hostsFingerprint([reordered])).toBe(hostsFingerprint([seeded]));
  });

  it("still notices a real change, including inside a nested offer", () => {
    const relay = (endpoint: string): HostEntry => ({
      id: "h2",
      type: "relay",
      label: "studio",
      offer: {
        v: 2,
        serverId: "srv-2",
        daemonPublicKeyB64: "AAAA",
        relay: { endpoint, useTls: true },
      },
    });
    expect(hostsFingerprint([relay("a:443")])).not.toBe(hostsFingerprint([relay("b:443")]));
  });

  it("ignores host order, which belongs to the Paseo app and not to the user", () => {
    const host = (id: string): HostEntry => ({
      id,
      label: id,
      type: "directTcp",
      endpoint: "127.0.0.1:6767",
      useTls: false,
    });
    // This assertion used to run the other way, from when the list came out
    // of a file the user edited and its order was theirs. It is another
    // program's serialization order now, and treating a reshuffle as a change
    // tears down and rebuilds every live connection for an identical set.
    expect(hostsFingerprint([host("a"), host("b")])).toBe(
      hostsFingerprint([host("b"), host("a")]),
    );
  });

  it("still separates two genuinely different host sets", () => {
    const host = (id: string): HostEntry => ({
      id,
      label: id,
      type: "directTcp",
      endpoint: "127.0.0.1:6767",
      useTls: false,
    });
    // Order-insensitive must not mean set-insensitive: dropping the sort key
    // from the comparison, or hashing only the ids, would pass the test above
    // and lose real changes here.
    expect(hostsFingerprint([host("a"), host("b")])).not.toBe(hostsFingerprint([host("a")]));
    expect(hostsFingerprint([host("a")])).not.toBe(hostsFingerprint([host("b")]));
  });
});
