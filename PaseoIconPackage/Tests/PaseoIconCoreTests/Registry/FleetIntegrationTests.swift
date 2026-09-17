import Foundation
import Testing
@testable import PaseoIconCore

/// The whole chain the app wires, minus AppKit: a registry read feeds the
/// fleet, the fleet dials a real `@getpaseo/server` 0.4.0 daemon, and the
/// store fills until the view model has a row to show. Slow by design.
@MainActor
struct FleetIntegrationTests {
    @Test("connects the fleet to a host the registry reports, and the menu shows it")
    func endToEnd() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let serverId = try daemon.string("serverId")

        let store = HostStore()
        let fleet = HostFleet(store: store, onEntryFailures: { _ in })
        let session = RegistrySession(
            readRegistry: {
                RegistrySnapshot(
                    hosts: [.directTcp(id: "srv_itest", label: "itest", endpoint: "127.0.0.1:\(port)", useTls: false, password: nil)],
                    failures: []
                )
            },
            watch: { _ in {} },
            applyConfig: { config in fleet.apply(config) },
            onConfigError: { message in store.setConfigError(message) },
            pollInterval: .zero
        )
        defer {
            session.stop()
            fleet.closeAll()
        }

        await session.start()

        #expect(await eventually(timeout: .seconds(30)) {
            store.snapshot().first(where: { $0.hostId == "srv_itest" })?.status == .connected
        })

        // A fresh daemon has no workspaces, so the menu is the empty state,
        // the host footer, and the actions: the shape a first launch shows.
        let model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.configError == nil)
        #expect(model.hostStatuses == [TrayHostStatus(hostId: "srv_itest", label: "itest", status: .connected)])
        #expect(store.snapshot().first?.serverId == serverId)

        let items = MenuModel.build(model, loginItemEnabled: false)
        #expect(items.contains(.note(index: 0, text: "No workspaces")))
        #expect(items.contains(.openApp))
        #expect(items.contains(.quit))
    }

    @Test("reports a host the registry could not map, without losing the one it could")
    func partialRegistry() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")

        let store = HostStore()
        let fleet = HostFleet(store: store, onEntryFailures: { _ in })
        let session = RegistrySession(
            readRegistry: {
                RegistrySnapshot(
                    hosts: [.directTcp(id: "srv_itest", label: "itest", endpoint: "127.0.0.1:\(port)", useTls: false, password: nil)],
                    failures: ["Pipe only — no connection the menu bar can use"]
                )
            },
            watch: { _ in {} },
            applyConfig: { config in fleet.apply(config) },
            onConfigError: { message in store.setConfigError(message) },
            pollInterval: .zero
        )
        defer {
            session.stop()
            fleet.closeAll()
        }

        await session.start()
        #expect(await eventually(timeout: .seconds(30)) {
            store.snapshot().first?.status == .connected
        })

        // The usable host connects and the unusable one is named: neither
        // costs the other.
        let model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
        #expect(model.hostStatuses.count == 1)
        #expect(try #require(model.configError).contains("Pipe only"))
        #expect(MenuModel.build(model, loginItemEnabled: false).first?.id == "configError")
    }
}
