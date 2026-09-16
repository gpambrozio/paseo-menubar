import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostFleetTests {
    /// Stands in for a real connection with the two store effects the fleet's
    /// bookkeeping depends on: registering the host on construction, and
    /// removing it in `close()`.
    @MainActor
    final class FakeConnections {
        private(set) var created: [(entry: HostEntry, closed: Bool)] = []
        /// Every construction and teardown, in the order they happened.
        private(set) var events: [String] = []
        var failOn: Set<String>

        init(failOn: Set<String> = []) {
            self.failOn = failOn
        }

        func make(_ entry: HostEntry, _ store: HostStore) throws -> any HostConnecting {
            if failOn.contains(entry.id) { throw FakeFailure(id: entry.id) }
            events.append("create:\(entry.id)")
            store.setHost(entry.id, label: entry.label, endpointHint: entry.endpointHint)
            let index = created.count
            created.append((entry, false))
            return FakeConnection { [weak self] in
                guard let self else { return }
                self.events.append("close:\(entry.id)")
                self.created[index].closed = true
                store.removeHost(entry.id)
            }
        }

        var ids: [String] { created.map(\.entry.id) }
        var leaked: [String] { created.filter { !$0.closed }.map(\.entry.id) }
    }

    /// A connection that records its own teardown and nothing else.
    @MainActor
    final class FakeConnection: HostConnecting {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func close() { onClose() }
    }

    struct FakeFailure: MessageError {
        let id: String
        var message: String { "cannot build a client for \(id)" }
    }

    @MainActor
    final class Harness {
        let store = HostStore()
        let connections: FakeConnections
        private(set) var failures: [[String]] = []
        private(set) var fleet: HostFleet!

        init(failOn: Set<String> = []) {
            connections = FakeConnections(failOn: failOn)
            fleet = HostFleet(
                store: store,
                onEntryFailures: { [weak self] entries in self?.failures.append(entries) },
                makeConnection: { [weak self] entry, store in
                    guard let self else { throw FakeFailure(id: entry.id) }
                    return try self.connections.make(entry, store)
                }
            )
        }

        var lastFailures: [String] { failures.last ?? [] }
    }

    @Test("keeps the rest of the fleet when one entry cannot be used")
    func isolatesBadEntry() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("good1"), Fixture.directEntry("bad"), Fixture.directEntry("good2")))

        // The entry after the bad one still connected.
        #expect(h.connections.ids == ["good1", "good2"])
        #expect(h.lastFailures == ["bad: cannot build a client for bad"])
    }

    @Test("shows the unusable host as invalid rather than hiding it")
    func showsInvalid() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad", label: "laptop")))

        let host = try #require(h.store.snapshot().first)
        #expect(host.hostId == "bad")
        #expect(host.label == "laptop")
        #expect(host.status == .invalid)
    }

    @Test("names the failure by endpoint when the unlabeled entry never reported anything else")
    func namesByEndpoint() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try AppConfig.validate(hosts: [.directTcp(id: "bad", label: nil, endpoint: "10.1.1.1:6767", useTls: false, password: nil)]))
        #expect(h.lastFailures == ["10.1.1.1:6767: cannot build a client for bad"])
    }

    @Test("refuses to build a second connection under an id that already has one")
    func duplicateId() throws {
        let h = Harness()
        // `AppConfig.validate` rejects this, so it can only arrive from a call
        // site that skipped validation. The map would otherwise overwrite the
        // first entry's connection, leaking a socket nothing can close.
        h.fleet.apply(AppConfig.unvalidated(hosts: [
            Fixture.directEntry("dup", label: "first"),
            Fixture.directEntry("dup", label: "second"),
        ]))

        #expect(h.connections.ids == ["dup"])
        #expect(h.lastFailures == ["second: a connection for host id \"dup\" already exists"])
        #expect(h.store.snapshot().first?.status == .invalid)
    }

    @Test("clears the failure list once the entries are fixed")
    func clearsFailures() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("good")))
        #expect(h.failures == [["bad: cannot build a client for bad"], []])
    }

    @Test("no-ops on a config whose host list is unchanged")
    func fingerprintGuard() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        // A distinct value with the same hosts: the registry comes back
        // through the watcher as a fresh parse, and must not churn sockets.
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))

        #expect(h.connections.ids == ["h1"])
        #expect(h.connections.leaked == ["h1"])
        #expect(h.failures.count == 1)
    }

    @Test("re-applies when the host list changes")
    func rebuildsOnChange() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", endpoint: "127.0.0.1:7000")))

        #expect(h.connections.ids == ["h1", "h1"])
        #expect(h.connections.leaked == ["h1"])
        #expect(h.store.snapshot().map(\.hostId) == ["h1"])
    }

    @Test("tears down one generation before building the next")
    func generationOrder() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("a1"), Fixture.directEntry("a2")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("b1")))

        // Each generation is a unit: every close of the old one precedes every
        // create of the new one, so no live connection is discarded unclosed.
        #expect(h.connections.events == ["create:a1", "create:a2", "close:a1", "close:a2", "create:b1"])
        #expect(h.connections.leaked == ["b1"])
        #expect(h.store.snapshot().map(\.hostId) == ["b1"])
    }

    @Test("closes the old connection before building the new one on retry")
    func retryOrder() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.retry("h1")

        #expect(h.connections.ids == ["h1", "h1"])
        #expect(h.connections.created.first?.closed == true)
        // `close()` removes the host from the store, so building the
        // replacement first would leave a live connection the store cannot see.
        #expect(h.store.snapshot().map(\.hostId) == ["h1"])
        #expect(h.connections.events == ["create:h1", "close:h1", "create:h1"])
    }

    @Test("names the host when the rebuild itself fails")
    func retryFailure() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", label: "laptop")))
        #expect(h.lastFailures.isEmpty)

        h.connections.failOn.insert("h1")
        h.fleet.retry("h1")

        // The tray shows `invalid` either way; without the report the error
        // row never says which host stopped working or why.
        #expect(h.store.snapshot().first?.status == .invalid)
        #expect(h.lastFailures == ["laptop: cannot build a client for h1"])
    }

    @Test("clears the host's failure once a retry rebuilds it")
    func retryClearsFailure() throws {
        let h = Harness(failOn: ["h1"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", label: "laptop"), Fixture.directEntry("h2")))
        #expect(h.lastFailures == ["laptop: cannot build a client for h1"])

        h.connections.failOn.remove("h1")
        h.fleet.retry("h1")
        #expect(h.lastFailures.isEmpty)
    }

    @Test("leaves the other hosts' failures alone when one is retried")
    func retryIsolated() throws {
        let h = Harness(failOn: ["h1", "h2"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1"), Fixture.directEntry("h2")))

        h.connections.failOn.remove("h1")
        h.fleet.retry("h1")
        #expect(h.lastFailures == ["h2: cannot build a client for h2"])
    }

    @Test("ignores a host that is not in the fleet")
    func retryUnknown() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.retry("nope")
        #expect(h.connections.ids == ["h1"])
    }

    @Test("derives a direct host's web UI from its endpoint, and a relay has none")
    func webBaseUrls() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(
            Fixture.directEntry("plain", endpoint: "192.168.1.4:6767"),
            Fixture.directEntry("tls", endpoint: "daemon.example.com:443", useTls: true),
            Fixture.relayEntry
        ))

        #expect(h.fleet.webBaseUrl(for: "plain") == "http://192.168.1.4:6767")
        #expect(h.fleet.webBaseUrl(for: "tls") == "https://daemon.example.com:443")
        // A relay is a socket tunnel, not an HTTP origin, so there is no fallback.
        #expect(h.fleet.webBaseUrl(for: "r1") == nil)
        #expect(h.fleet.webBaseUrl(for: "not-a-host") == nil)
    }

    @Test("forgets a host's URL once it leaves the config")
    func forgetsUrl() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h2")))
        #expect(h.fleet.webBaseUrl(for: "h1") == nil)
        #expect(h.fleet.webBaseUrl(for: "h2") == "http://127.0.0.1:6767")
    }

    @Test("picks the first connected direct host in config order, skipping a relay")
    func firstWebBaseUrl() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.relayEntry, Fixture.directEntry("h1", endpoint: "192.168.1.4:6767")))
        h.store.setStatus("h1", .connected)
        #expect(h.fleet.firstWebBaseUrl() == "http://192.168.1.4:6767")
    }

    @Test("skips a host whose entry never became a live connection")
    func skipsUnbuilt() throws {
        // "bad" has a good endpoint and fails for another reason, so its entry
        // would happily yield a URL. Offering it would send the user to a host
        // that never connected.
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad"), Fixture.directEntry("good", endpoint: "10.0.0.9:6767")))
        h.store.setStatus("good", .connected)
        #expect(h.fleet.firstWebBaseUrl() == "http://10.0.0.9:6767")
    }

    @Test("offers no URL unless a host is both live and a direct connection")
    func noFallback() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad"), Fixture.relayEntry))
        h.store.setStatus("r1", .connected)
        #expect(h.fleet.firstWebBaseUrl() == nil)
    }

    @Test("skips connecting, disconnected, and unauthorized hosts to offer the one that is connected")
    func skipsEveryOtherStatus() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(
            Fixture.directEntry("connecting", endpoint: "10.0.0.1:6767"),
            Fixture.directEntry("down", endpoint: "10.0.0.2:6767"),
            Fixture.directEntry("locked", endpoint: "10.0.0.3:6767"),
            Fixture.directEntry("up", endpoint: "10.0.0.4:6767")
        ))
        h.store.setStatus("down", .disconnected)
        h.store.setStatus("locked", .unauthorized)
        h.store.setStatus("up", .connected)

        // Each of the three skipped statuses still yields a URL from the entry
        // alone, which would suppress the actionable `paseo://` fallback.
        #expect(h.fleet.firstWebBaseUrl() == "http://10.0.0.4:6767")
    }

    @Test("closes every live connection on shutdown")
    func closeAll() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1"), Fixture.directEntry("h2")))
        h.fleet.closeAll()
        #expect(h.connections.leaked.isEmpty)
    }
}
