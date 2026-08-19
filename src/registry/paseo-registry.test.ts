import { describe, expect, it } from "vitest";
import { hostEntriesFromRegistry } from "./paseo-registry.js";

function profile(overrides: Record<string, unknown> = {}) {
  return {
    serverId: "srv_one",
    label: "Mac.localdomain",
    lifecycle: {},
    connections: [{ id: "direct:localhost:6767", type: "directTcp", endpoint: "localhost:6767" }],
    preferredConnectionId: "direct:localhost:6767",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("hostEntriesFromRegistry", () => {
  it("maps a direct TCP host, keying it by serverId", () => {
    const { hosts, failures } = hostEntriesFromRegistry(JSON.stringify([profile()]));
    expect(failures).toEqual([]);
    expect(hosts).toEqual([
      {
        id: "srv_one",
        label: "Mac.localdomain",
        type: "directTcp",
        endpoint: "localhost:6767",
        useTls: false,
      },
    ]);
  });

  it("rebuilds a relay offer from the stored connection", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          serverId: "srv_two",
          label: "ai-mbp.local",
          connections: [
            {
              id: "relay:wss:relay.paseo.sh:443",
              type: "relay",
              relayEndpoint: "relay.paseo.sh:443",
              useTls: true,
              daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
            },
          ],
          preferredConnectionId: "relay:wss:relay.paseo.sh:443",
        }),
      ]),
    );
    expect(hosts[0]).toEqual({
      id: "srv_two",
      label: "ai-mbp.local",
      type: "relay",
      offer: {
        v: 2,
        serverId: "srv_two",
        daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("keeps two relay hosts apart even though their connection ids are identical", () => {
    const shared = {
      id: "relay:wss:relay.paseo.sh:443",
      type: "relay",
      relayEndpoint: "relay.paseo.sh:443",
      useTls: true,
      daemonPublicKeyB64: "AAAA",
    };
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({ serverId: "srv_a", connections: [shared], preferredConnectionId: shared.id }),
        profile({ serverId: "srv_b", connections: [shared], preferredConnectionId: shared.id }),
      ]),
    );
    expect(hosts.map((host) => host.id)).toEqual(["srv_a", "srv_b"]);
  });

  it("falls back to a supported connection when the preferred one is not", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "pipe:1", type: "directPipe", path: "/tmp/sock" },
            { id: "direct:1", type: "directTcp", endpoint: "10.0.0.9:6767" },
          ],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toHaveLength(1);
    expect(hosts[0]).toMatchObject({ type: "directTcp", endpoint: "10.0.0.9:6767" });
  });

  it("drops a host with no supported connection and names it in failures", () => {
    const { hosts, failures } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          label: "Pipe only",
          connections: [{ id: "pipe:1", type: "directPipe", path: "/tmp/sock" }],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toEqual([]);
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("Pipe only");
  });

  it("carries a direct host's password through", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "d", type: "directTcp", endpoint: "10.0.0.9:6767", useTls: true, password: "hunter2" },
          ],
          preferredConnectionId: "d",
        }),
      ]),
    );
    expect(hosts[0]).toMatchObject({ useTls: true, password: "hunter2" });
  });

  it("throws on JSON that is not an array of profiles", () => {
    expect(() => hostEntriesFromRegistry('{"nope":true}')).toThrow();
  });

  it("throws on malformed JSON rather than returning an empty host list", () => {
    expect(() => hostEntriesFromRegistry("{{{")).toThrow();
  });
});
