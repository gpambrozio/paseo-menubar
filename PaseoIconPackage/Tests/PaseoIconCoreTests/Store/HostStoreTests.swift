import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostStoreTests {
    private func seeded() -> HostStore {
        let store = HostStore()
        store.setHost("h1", label: "laptop", endpointHint: "127.0.0.1:6767")
        return store
    }

    @Test("seeds a host and reports its workspaces and agents")
    func seeds() throws {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: false)

        let host = try #require(store.snapshot().first)
        #expect(host.label == "laptop")
        #expect(host.agents.map(\.id) == ["a", "b"])
        #expect(host.workspaces.map(\.id) == ["w1"])
    }

    @Test("applies an agent upsert as a full replacement")
    func agentUpsert() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a", status: "idle")], truncated: false)
        store.applyAgentUpdate("h1", .upsert(Fixture.agent("a", status: "running")))
        #expect(store.snapshot().first?.agents.first?.status == "running")
    }

    @Test("applies a workspace upsert as a full replacement")
    func workspaceUpsert() {
        let store = seeded()
        store.seedWorkspaces("h1", [Fixture.workspace("w1", status: "done")], truncated: false)
        store.applyWorkspaceUpdate("h1", .upsert(Fixture.workspace("w1", status: "needs_input")))
        #expect(store.snapshot().first?.workspaces.first?.status == "needs_input")
    }

    @Test("applies an agent remove and a workspace remove")
    func removes() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1"), Fixture.workspace("w2")], truncated: false)
        store.applyAgentUpdate("h1", .remove(agentId: "a"))
        store.applyWorkspaceUpdate("h1", .remove(id: "w1"))
        #expect(store.snapshot().first?.agents.map(\.id) == ["b"])
        #expect(store.snapshot().first?.workspaces.map(\.id) == ["w2"])
    }

    @Test("re-seeding replaces wholesale so a subscription gap cannot strand a row")
    func reseedReplaces() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedAgents("h1", [Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1"), Fixture.workspace("w2")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w2")], truncated: false)
        #expect(store.snapshot().first?.agents.map(\.id) == ["b"])
        #expect(store.snapshot().first?.workspaces.map(\.id) == ["w2"])
    }

    @Test("tracks status and serverId per host")
    func statusAndServerId() {
        let store = seeded()
        #expect(store.snapshot().first?.status == .connecting)
        store.setStatus("h1", .connected)
        store.setServerId("h1", "srv-1")
        #expect(store.snapshot().first?.status == .connected)
        #expect(store.snapshot().first?.serverId == "srv-1")
    }

    @Test("tracks the daemon's hostname the same way it tracks serverId")
    func hostname() {
        let store = seeded()
        var notifications = 0
        _ = store.subscribe { notifications += 1 }

        #expect(store.snapshot().first?.hostname == nil)
        store.setHostname("h1", "build-box.local")
        #expect(store.snapshot().first?.hostname == "build-box.local")
        #expect(notifications == 1)

        // Same value again: no-op, matching setServerId and setStatus.
        store.setHostname("h1", "build-box.local")
        #expect(notifications == 1)

        store.setHostname("h1", "new-name.local")
        #expect(notifications == 2)
    }

    @Test("leaves the label nil when the entry has none, rather than inventing one")
    func noLabel() {
        let store = HostStore()
        store.setHost("h1", label: nil, endpointHint: "127.0.0.1:6767")
        #expect(store.snapshot().first?.label == nil)
        #expect(store.snapshot().first?.endpointHint == "127.0.0.1:6767")
    }

    @Test("carries each seed's truncation flag independently and clears it on a complete re-seed")
    func truncation() {
        let store = seeded()
        #expect(store.snapshot().first?.workspacesTruncated == false)
        #expect(store.snapshot().first?.agentsTruncated == false)

        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: true)
        store.seedAgents("h1", [Fixture.agent("a")], truncated: false)
        #expect(store.snapshot().first?.workspacesTruncated == true)
        #expect(store.snapshot().first?.agentsTruncated == false)

        store.seedAgents("h1", [Fixture.agent("a")], truncated: true)
        #expect(store.snapshot().first?.agentsTruncated == true)

        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: false)
        #expect(store.snapshot().first?.workspacesTruncated == false)
    }

    @Test("removing a host drops it entirely")
    func removeHost() {
        let store = seeded()
        store.removeHost("h1")
        #expect(store.snapshot().isEmpty)
    }

    @Test("holds a configuration error and notifies only when it changes")
    func configError() {
        let store = HostStore()
        var notifications = 0
        _ = store.subscribe { notifications += 1 }

        #expect(store.getConfigError() == nil)
        store.setConfigError("broken")
        store.setConfigError("broken")
        #expect(store.getConfigError() == "broken")
        #expect(notifications == 1)

        store.setConfigError(nil)
        #expect(store.getConfigError() == nil)
        #expect(notifications == 2)
    }

    @Test("notifies subscribers on change and stops after unsubscribe")
    func subscription() {
        let store = HostStore()
        var notifications = 0
        let unsubscribe = store.subscribe { notifications += 1 }

        store.setHost("h1", label: "laptop", endpointHint: "127.0.0.1:6767")
        #expect(notifications == 1)

        unsubscribe()
        store.setStatus("h1", .connected)
        #expect(notifications == 1)
    }

    @Test("ignores updates for unknown hosts instead of trapping")
    func unknownHost() {
        let store = HostStore()
        store.applyAgentUpdate("nope", .remove(agentId: "a"))
        store.applyWorkspaceUpdate("nope", .remove(id: "w"))
        store.seedAgents("nope", [Fixture.agent("a")], truncated: false)
        #expect(store.snapshot().isEmpty)
    }

    @Test("keeps hosts in the order they were registered, not a dictionary's order")
    func registrationOrder() {
        let store = HostStore()
        for id in ["zebra", "apple", "middle"] {
            store.setHost(id, label: id, endpointHint: "127.0.0.1:6767")
        }
        // The menu's host rows follow config order; sorting by id would put
        // "apple" first and silently reorder the footer on every render.
        #expect(store.snapshot().map(\.hostId) == ["zebra", "apple", "middle"])
    }
}
