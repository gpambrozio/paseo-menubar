import Clocks
import Testing
@testable import PaseoIconCore

@MainActor
struct RouteFailoverConnectionTests {
    private static let hostId = "studio"

    private static func entry(_ endpoint: String) -> HostEntry {
        .directTcp(id: hostId, label: "Studio", endpoint: endpoint, useTls: false, password: nil)
    }

    @MainActor
    private final class Harness {
        let clock = TestClock()
        let factory = Factory()
        let sink = RecordingSink()
        let primary = entry("preferred.test:6767")
        let fallback = entry("fallback.test:6767")
        let connection: RouteFailoverConnection

        init() throws {
            connection = try RouteFailoverConnection(
                entries: [primary, fallback], sink: sink, clock: clock, makeConnection: factory.make
            )
        }
    }

    @MainActor
    private final class Factory {
        private(set) var attempts: [Attempt] = []

        func make(_ entry: HostEntry, sink: any HostSink) -> any HostConnecting {
            #expect(attempts.allSatisfy { $0.closeCalls == 1 })
            let attempt = Attempt(entry: entry, sink: sink)
            attempts.append(attempt)
            sink.setHost(entry.id, label: entry.label, endpointHint: entry.endpointHint)
            attempt.status(.connecting)
            return attempt
        }
    }

    @MainActor
    private final class Attempt: HostConnecting {
        let entry: HostEntry
        let sink: any HostSink
        private(set) var closeCalls = 0

        init(entry: HostEntry, sink: any HostSink) {
            self.entry = entry
            self.sink = sink
        }

        func status(_ status: HostStatus) {
            sink.setStatus(entry.id, status)
        }

        func close() {
            closeCalls += 1
            status(.disconnected)
            sink.removeHost(entry.id)
        }
    }

    @Test("fails over to a route that seeds the same host")
    func fallbackSeedsSameHost() async throws {
        let h = try Harness()
        defer { h.connection.close() }
        let first = try #require(h.factory.attempts.first)
        #expect(first.entry == h.primary)
        first.status(.disconnected)
        #expect(h.factory.attempts.count == 1)
        await settle()

        let fallback = try #require(h.factory.attempts.last)
        #expect(h.factory.attempts.map(\.entry) == [h.primary, h.fallback])
        #expect(fallback.closeCalls == 0)
        let beforeStaleCallbacks = h.sink.events
        first.status(.securityRejected)
        first.sink.setHostname(Self.hostId, "stale")
        first.sink.setHost(Self.hostId, label: nil, endpointHint: "stale")
        first.sink.seedWorkspaces(Self.hostId, [], truncated: false)
        first.sink.applyAgentUpdate(Self.hostId, .remove(agentId: "stale"))
        #expect(h.sink.events == beforeStaleCallbacks)

        fallback.sink.seedAgents(Self.hostId, [], truncated: false)
        fallback.sink.seedWorkspaces(Self.hostId, [], truncated: true)
        fallback.sink.setServerId(Self.hostId, "studio-server")
        fallback.status(.connected)
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.attempts.count == 2)
        #expect(Array(h.sink.events.suffix(4)) == [
            .seedAgents(Self.hostId, ids: [], truncated: false),
            .seedWorkspaces(Self.hostId, ids: [], truncated: true),
            .setServerId(Self.hostId, "studio-server"),
            .setStatus(Self.hostId, .connected),
        ])
        #expect(!h.sink.events.contains(.removeHost(Self.hostId)))

        h.connection.close()
        fallback.status(.connected)
        fallback.sink.setHost(Self.hostId, label: nil, endpointHint: "closed")
        #expect(fallback.closeCalls == 1)
        #expect(h.sink.events.last == .removeHost(Self.hostId))
    }

    @Test("keeps the fatal status and closes the route without trying a sibling",
          arguments: [HostStatus.unauthorized, .securityRejected, .incompatibleProtocol, .invalid])
    func fatalFailure(_ fatal: HostStatus) async throws {
        let h = try Harness()
        defer { h.connection.close() }
        let first = try #require(h.factory.attempts.first)
        first.status(.disconnected)
        first.status(fatal)
        await settle()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.attempts.count == 1)
        #expect(first.closeCalls == 1)
        #expect(h.sink.statuses.last == fatal)
        #expect(!h.sink.events.contains(.removeHost(Self.hostId)))
    }

    @Test("backs off after each failed cycle and cancels the pending dial on close")
    func cycleBackoff() async throws {
        let h = try Harness()
        defer { h.connection.close() }

        for delay in [1500, 3000] {
            try #require(h.factory.attempts.last).status(.disconnected)
            await settle()
            let fallback = try #require(h.factory.attempts.last)
            #expect(fallback.entry == h.fallback)
            fallback.status(.disconnected)
            fallback.status(.disconnected)
            await settle()
            let attemptsBeforeDelay = h.factory.attempts.count
            #expect(fallback.closeCalls == 1)
            #expect(h.factory.attempts.allSatisfy { $0.closeCalls == 1 })
            await h.clock.advance(by: .milliseconds(delay - 1))
            #expect(h.factory.attempts.count == attemptsBeforeDelay)
            await h.clock.advance(by: .milliseconds(1))
            #expect(h.factory.attempts.count == attemptsBeforeDelay + 1)
            let primary = try #require(h.factory.attempts.last)
            #expect(primary.entry == h.primary)
            #expect(primary.closeCalls == 0)
        }

        try #require(h.factory.attempts.last).status(.disconnected)
        await settle()
        try #require(h.factory.attempts.last).status(.disconnected)
        await settle()
        let attemptsBeforeClose = h.factory.attempts.count
        h.connection.close()
        await h.clock.advance(by: .seconds(60))
        #expect(h.factory.attempts.count == attemptsBeforeClose)
        #expect(h.sink.events.last == .removeHost(Self.hostId))
    }
}
