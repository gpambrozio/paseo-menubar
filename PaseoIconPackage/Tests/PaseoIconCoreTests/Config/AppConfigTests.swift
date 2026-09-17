import Foundation
import Testing
@testable import PaseoIconCore

/// Ports the `hostsFingerprint` half of `src/config/host-entry.test.ts`, plus
/// the validation rules that file's schema expressed in zod.
struct AppConfigTests {
    private func direct(_ id: String, label: String? = nil, endpoint: String = "127.0.0.1:6767") -> HostEntry {
        .directTcp(id: id, label: label ?? id, endpoint: endpoint, useTls: false, password: nil)
    }

    private func relay(_ id: String, endpoint: String = "relay.paseo.sh:443", key: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=") -> HostEntry {
        .relay(id: id, label: "studio", offer: ConnectionOffer(serverId: "srv-\(id)", daemonPublicKeyB64: key, relay: .init(endpoint: endpoint, useTls: true)))
    }

    @Test("accepts a well-formed host set")
    func accepts() throws {
        let config = try AppConfig.validate(hosts: [direct("a"), relay("b")])
        #expect(config.hosts.map(\.id) == ["a", "b"])
        #expect(config.version == 1)
    }

    @Test("rejects two entries under one id, which would orphan a connection")
    func duplicateIds() {
        // The id keys the fleet's connection map: the second entry would
        // overwrite the first, leaving a socket and subscription nothing stops.
        #expect(throws: AppConfigError.self) {
            try AppConfig.validate(hosts: [direct("a"), direct("a", endpoint: "10.0.0.1:6767")])
        }
        do {
            _ = try AppConfig.validate(hosts: [direct("a"), direct("a")])
        } catch let error as AppConfigError {
            #expect(error.message.contains("Duplicate host id"))
            #expect(error.message.contains("\"a\""))
        } catch {
            Issue.record("expected AppConfigError")
        }
    }

    @Test("rejects a relay entry whose offer fields are empty")
    func emptyOffer() {
        // The only thing between an empty credential read out of another
        // program's storage and the connection code.
        let hosts: [HostEntry] = [.relay(id: "r", label: nil, offer: ConnectionOffer(serverId: "srv", daemonPublicKeyB64: "", relay: .init(endpoint: "", useTls: true)))]
        #expect(throws: AppConfigError.self) { try AppConfig.validate(hosts: hosts) }
    }

    @Test("rejects a label that is present but empty")
    func emptyLabel() {
        #expect(throws: AppConfigError.self) {
            try AppConfig.validate(hosts: [.directTcp(id: "a", label: "", endpoint: "127.0.0.1:6767", useTls: false, password: nil)])
        }
    }

    @Test("unvalidated skips every rule, which is the only way to reach the fleet's own guard")
    func unvalidated() {
        let config = AppConfig.unvalidated(hosts: [direct("dup"), direct("dup")])
        #expect(config.hosts.count == 2)
    }

    @Test("the fingerprint ignores host order, which belongs to the Paseo app and not the user")
    func orderInsensitive() {
        // Treating a reshuffle as a change tears down and rebuilds every live
        // connection for an identical set.
        #expect(hostsFingerprint([direct("a"), direct("b")]) == hostsFingerprint([direct("b"), direct("a")]))
    }

    @Test("the fingerprint still separates two genuinely different host sets")
    func setSensitive() {
        // Order-insensitive must not mean set-insensitive: hashing only the
        // ids, or dropping the sort key, would pass the test above and lose
        // real changes here.
        #expect(hostsFingerprint([direct("a"), direct("b")]) != hostsFingerprint([direct("a")]))
        #expect(hostsFingerprint([direct("a")]) != hostsFingerprint([direct("b")]))
    }

    @Test("the fingerprint notices a change inside a nested offer")
    func nestedChange() {
        #expect(hostsFingerprint([relay("r", endpoint: "a:443")]) != hostsFingerprint([relay("r", endpoint: "b:443")]))
        #expect(hostsFingerprint([relay("r", key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")]) != hostsFingerprint([relay("r", key: "f39/f39/f39/f39/f39/f39/f39/f39/f39/f39/f38=")]))
    }

    @Test("the fingerprint notices a change to a field the encoder writes last")
    func fieldOrderIndependence() {
        // `HostEntry`'s custom encoder writes id and label first; a fingerprint
        // that only looked at a prefix would miss the rest.
        #expect(hostsFingerprint([direct("a", endpoint: "10.0.0.1:6767")]) != hostsFingerprint([direct("a", endpoint: "10.0.0.2:6767")]))
    }

    @Test("a host entry survives a Codable round trip unchanged")
    func codableRoundTrip() throws {
        for entry in [direct("a", label: "laptop"), relay("b")] {
            let data = try JSONEncoder().encode(entry)
            #expect(try JSONDecoder().decode(HostEntry.self, from: data) == entry)
        }
    }
}
