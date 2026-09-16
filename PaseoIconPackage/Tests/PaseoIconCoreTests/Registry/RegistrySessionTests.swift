import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct RegistrySessionTests {
    private static func host(_ id: String) -> HostEntry {
        .directTcp(id: id, label: id, endpoint: "10.0.0.1:6767", useTls: false, password: nil)
    }

    /// Reads are supplied one per call, sticking on the last entry.
    @MainActor
    final class Harness {
        enum Read {
            case snapshot(RegistrySnapshot?)
            case failure(String)
        }

        let clock = TestClock()
        private(set) var applied: [AppConfig] = []
        private(set) var errors: [String?] = []
        private(set) var afterReads = 0
        private(set) var reads = 0
        private(set) var unwatched = false
        var fire: () -> Void = {}
        /// Set to make the next apply throw with this message.
        var applyFailure: String?
        /// Set to make an apply throw only when the config holds this host id.
        var applyFailureFor: String?
        var script: [Read]
        /// Set to answer every later read with this snapshot, ignoring the script.
        var current: RegistrySnapshot?
        /// Built after the stored properties so the callbacks can capture self.
        private(set) var session: RegistrySession!

        init(_ script: [Read], pollInterval: Duration = .zero) {
            self.script = script
            session = RegistrySession(
                readRegistry: { [weak self] in
                    guard let self else { return nil }
                    return try self.nextRead()
                },
                watch: { [weak self] onChange in
                    self?.fire = onChange
                    return { [weak self] in self?.unwatched = true }
                },
                applyConfig: { [weak self] config in
                    guard let self else { return }
                    try self.apply(config)
                },
                onConfigError: { [weak self] message in self?.errors.append(message) },
                afterRead: { [weak self] in self?.afterReads += 1 },
                pollInterval: pollInterval,
                clock: clock
            )
        }

        func nextRead() throws -> RegistrySnapshot? {
            reads += 1
            if let current { return current }
            let index = min(reads - 1, script.count - 1)
            switch script[index] {
            case .snapshot(let snapshot): return snapshot
            case .failure(let message): throw LevelDBReadError(message: message, cause: nil)
            }
        }

        func apply(_ config: AppConfig) throws {
            if let failure = applyFailure {
                applyFailure = nil
                throw LevelDBReadError(message: failure, cause: nil)
            }
            if let id = applyFailureFor, config.hosts.contains(where: { $0.id == id }) {
                throw LevelDBReadError(message: "fleet rebuild blew up", cause: nil)
            }
            applied.append(config)
        }

        var lastError: String? { errors.last ?? nil }
    }

    @Test("applies the hosts it read and clears the error row")
    func appliesHosts() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        await h.session.start()
        #expect(h.applied.count == 1)
        #expect(h.applied.first?.hosts.map(\.id) == ["a"])
        #expect(h.lastError == nil)
    }

    @Test("does not rebuild the fleet when the host set is unchanged")
    func unchangedSet() async {
        let snapshot = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        let h = Harness([.snapshot(snapshot), .snapshot(snapshot)])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 1)
    }

    @Test("rebuilds when the host set actually changes")
    func changedSet() async {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .snapshot(RegistrySnapshot(hosts: [Self.host("a"), Self.host("b")], failures: [])),
        ])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.map(\.id) == ["a", "b"])
    }

    @Test("keeps the last known-good hosts when a later read fails")
    func readFailure() async throws {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .failure("torn read"),
        ])
        await h.session.start()
        await h.session.refresh()
        // Nothing re-applied: the good host set stays live.
        #expect(h.applied.count == 1)
        #expect(try #require(h.lastError).contains("torn read"))
    }

    @Test("applies an empty host set when the registry key is absent")
    func absentKey() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])), .snapshot(nil)])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.isEmpty == true)
        #expect(try #require(h.lastError).contains("No hosts yet"))
    }

    @Test("applies the hosts it got and still reports a partly unreadable database")
    func warningWithHosts() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(
            hosts: [Self.host("a")],
            failures: [],
            warning: "Could not read 1 of 2 LevelDB file(s) in /db; the host list may be out of date"
        ))])
        await h.session.start()
        // Dropping the hosts over one torn file empties the tray; dropping the
        // warning presents a possibly-superseded host list as healthy.
        #expect(h.applied.first?.hosts.map(\.id) == ["a"])
        #expect(try #require(h.lastError).contains("out of date"))
    }

    @Test("refuses a host set the config validation rejects, and keeps the last good one")
    func duplicateIds() async throws {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .snapshot(RegistrySnapshot(hosts: [Self.host("a"), Self.host("a")], failures: [])),
        ])
        await h.session.start()
        await h.session.refresh()
        // Two entries under one id would leave an orphaned connection whose
        // socket and subscription never stop.
        #expect(h.applied.count == 1)
        #expect(try #require(h.lastError).contains("Duplicate host id"))
    }

    @Test("refuses a relay entry whose offer fields are empty")
    func emptyOfferFields() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(
            hosts: [.relay(id: "r1", label: nil, offer: ConnectionOffer(serverId: "srv", daemonPublicKeyB64: "", relay: .init(endpoint: "", useTls: true)))],
            failures: []
        ))])
        await h.session.start()
        // The offer's own constraints are the only thing between an empty
        // credential from the registry and the connection code.
        #expect(h.applied.isEmpty)
        #expect(try #require(h.lastError).contains("could not be used"))
    }

    @Test("points at the Paseo app when the registry holds an empty host array")
    func emptyRegistry() async throws {
        // Distinct from an absent key: Paseo is installed and has stored a
        // registry, it is just empty. Without a row the user gets zero hosts
        // and no route forward at all.
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [], failures: []))])
        await h.session.start()
        #expect(h.applied.count == 1)
        #expect(h.applied.first?.hosts.isEmpty == true)
        #expect(try #require(h.lastError).contains("No hosts yet"))
    }

    @Test("re-applies the host set after applyConfig fails, rather than marking it applied")
    func applyFailure() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        h.applyFailure = "fleet rebuild blew up"
        await h.session.start()
        #expect(h.applied.isEmpty)
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))

        // The fingerprint must not have been claimed: the next read sees the
        // same host set, and if it counted as applied the fleet would never
        // receive it while the successful read cleared the error row.
        await h.session.refresh()
        #expect(h.applied.count == 1)
        #expect(h.lastError == nil)
    }

    @Test("re-applies the previous host set when the registry reverts after a failed apply")
    func revertAfterFailedApply() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        h.current = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        await h.session.start()
        #expect(h.applied.count == 1)

        // The fleet tears down before it rebuilds, so a rebuild that throws
        // leaves it empty; whatever was live before is gone too.
        h.current = RegistrySnapshot(hosts: [Self.host("b")], failures: [])
        h.applyFailureFor = "b"
        await h.session.refresh()
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))

        // The user reverts in Paseo. Treating that as "unchanged" left the
        // fleet empty with a clear error row: no hosts, no error, no way back.
        h.current = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.map(\.id) == ["a"])
        #expect(h.lastError == nil)
    }

    @Test("keeps the read's own problems in the row when the apply fails")
    func problemsSurviveFailedApply() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: ["Pipe only — no connection the menu bar can use"]))])
        h.applyFailure = "fleet rebuild blew up"
        await h.session.start()
        // Both are true at once and both are the user's to act on.
        #expect(try #require(h.lastError).contains("Pipe only"))
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))
    }

    @Test("runs afterRead after every read, failed ones included")
    func afterReadHook() async {
        let h = Harness([.failure("Paseo desktop app not found")])
        await h.session.start()
        // A failed read is exactly the case that matters: the directory was
        // absent at launch, and this is what re-checks for it on every poll.
        #expect(h.afterReads == 1)
        await h.session.refresh()
        #expect(h.afterReads == 2)
    }

    @Test("stop cancels the pending read, the poll, and the watcher")
    func stopCancels() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))], pollInterval: .milliseconds(100))
        await h.session.start()
        #expect(h.reads == 1)

        h.fire() // schedules a debounced read that stop() has to cancel
        h.session.stop()
        await h.clock.advance(by: .seconds(2))
        await settle()

        #expect(h.unwatched)
        #expect(h.reads == 1)
    }

    @Test("debounces a burst of watcher events into one read")
    func debounces() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        await h.session.start()
        #expect(h.reads == 1)
        h.fire()
        h.fire()
        h.fire()
        await settle()
        await h.clock.advance(by: .milliseconds(600))
        await settle()
        #expect(h.reads == 2)
        h.session.stop()
    }

    @Test("polls on its own interval as a safety net for events the watcher missed")
    func polls() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))], pollInterval: .seconds(60))
        await h.session.start()
        #expect(h.reads == 1)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.reads == 2)
        h.session.stop()
    }

    @Test("surfaces dropped hosts in the error row")
    func droppedHosts() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: ["Pipe only — no connection the menu bar can use"]))])
        await h.session.start()
        #expect(try #require(h.lastError).contains("Pipe only"))
    }

    @Test("shows a registry problem and a fleet problem at the same time")
    func bothProblems() async throws {
        let h = Harness([.snapshot(nil)])
        await h.session.start()
        h.session.noteEntryFailures(["h1 — unreachable"])
        #expect(try #require(h.lastError).contains("No hosts yet"))
        #expect(try #require(h.lastError).contains("h1 — unreachable"))
    }

    @Test("clearing the fleet's problems does not clear the registry's")
    func independentProblems() async throws {
        let h = Harness([.snapshot(nil)])
        await h.session.start()
        h.session.noteEntryFailures(["h1 — unreachable"])
        h.session.noteEntryFailures([])
        #expect(try #require(h.lastError).contains("No hosts yet"))
        #expect(!(try #require(h.lastError).contains("unreachable")))
    }

    @Test("never throws when the first read fails")
    func firstReadFails() async throws {
        let h = Harness([.failure("nope")])
        await h.session.start()
        #expect(try #require(h.lastError).contains("nope"))
    }
}
