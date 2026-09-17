import AppKit
import PaseoIconCore
import ServiceManagement
import SwiftUI

/// Wiring, and only wiring. Every decision this reads from belongs to
/// `PaseoIconCore`: the store holds the state, the view model turns it into a
/// menu, and the registry session decides when to re-read. What lives here is
/// what genuinely needs AppKit — opening URLs, the login item, alerts — plus
/// the object graph that connects them.
@MainActor
@Observable
final class AppCoordinator {
    private(set) var model: TrayViewModel = .empty
    private(set) var loginItemEnabled = false

    @ObservationIgnored private let store = HostStore()
    @ObservationIgnored private var fleet: HostFleet!
    @ObservationIgnored private var session: RegistrySession!
    @ObservationIgnored private var watcher: RegistryWatcher!
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Renders are coalesced: a seed lands as several store writes in a row,
    /// and rebuilding the menu for each is work nobody sees.
    private static let rebuildDebounce = Duration.milliseconds(120)

    init() {
        fleet = HostFleet(
            store: store,
            onEntryFailures: { [weak self] failures in self?.session?.noteEntryFailures(failures) }
        )
        watcher = RegistryWatcher(
            resolveDir: { try PaseoRegistry.levelDbDir(appSupportDir: Self.applicationSupportDirectory()) },
            open: { dir, onChange, onError in
                try FSEventsWatch.open(directory: dir, onChange: onChange, onError: onError)
            }
        )
        session = RegistrySession(
            // Detached on purpose. A closure formed in a `@MainActor` init is
            // isolated to the main actor, so awaiting it would run the whole
            // read — listing the directory, verifying every block's CRC32C,
            // decompressing snappy — between two frames of the menu bar. The
            // TypeScript this ports was async over `fs/promises` and never had
            // that problem.
            readRegistry: {
                try await Task.detached {
                    try PaseoRegistry.read(appSupportDir: Self.applicationSupportDirectory())
                }.value
            },
            watch: { [weak self] onChange in self?.watcher.watch(onChange) ?? {} },
            applyConfig: { [weak self] config in self?.fleet.apply(config) },
            onConfigError: { [weak self] message in self?.store.setConfigError(message) },
            // A read that ran means the directory may exist now even if it did
            // not at launch, which is what makes installing Paseo mid-session
            // take effect on the next poll rather than never.
            afterRead: { [weak self] in self?.watcher.ensureAttached() }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        unsubscribe = store.subscribe { [weak self] in self?.scheduleRebuild() }
        refreshLoginItem()
        rebuild()
        Task { await session.start() }
    }

    func stop() {
        session?.stop()
        rebuildTask?.cancel()
        unsubscribe?()
        fleet?.closeAll()
    }

    // MARK: - Menu actions

    func openWorkspace(_ row: TrayWorkspaceRow) {
        // Every routing decision, including the missing-serverId one, lives in
        // `OpenPaseo` where a test can reach it. This method only opens.
        open(OpenPaseo.workspace(
            OpenWorkspaceTarget(
                serverId: row.serverId,
                workspaceId: row.workspaceId,
                agentId: row.agentId,
                webBaseUrl: fleet.webBaseUrl(for: row.hostId),
                // A connected host's URL, not this one's: without a serverId
                // this host has not handshaked, so its own origin cannot load.
                fallbackWebBaseUrl: fleet.firstWebBaseUrl()
            ),
            desktopAppInstalled: OpenPaseo.defaultDesktopAppInstalled()
        ))
    }

    func openApp() {
        open(OpenPaseo.app(webBaseUrl: fleet.firstWebBaseUrl(), desktopAppInstalled: OpenPaseo.defaultDesktopAppInstalled()))
    }

    func retryHost(_ hostId: String) {
        fleet.retry(hostId)
    }

    func showConfigError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Paseo Icon — configuration"
        alert.informativeText = detail
        alert.addButton(withTitle: "Open Paseo")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openApp() }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // `swift run` has no bundle to register, and a user can decline in
            // System Settings. Neither is worth killing the tray over.
            report(title: "Paseo Icon — could not change the login item", detail: errorText(error))
        }
        refreshLoginItem()
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Internals

    private func refreshLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        // Guarded, because this runs on every rebuild and an unconditional
        // write invalidates every observer whether or not anything changed.
        if enabled != loginItemEnabled { loginItemEnabled = enabled }
    }

    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.rebuildDebounce)
            } catch {
                // Cancelled by `stop()`. Swallowing this with `try?` would let
                // the rebuild run anyway, which is not what cancelling means.
                // The handle is cleared so it does not outlive the task it
                // names; `start()` is one-shot, so nothing reschedules after.
                self?.rebuildTask = nil
                return
            }
            guard let self else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    private func rebuild() {
        // Re-read on every rebuild, the way the Electron menu re-read it on
        // every render. The switch lives in System Settings, outside this app,
        // so a checkmark that only updates on relaunch is simply wrong.
        refreshLoginItem()
        model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
    }

    private func open(_ target: OpenTarget) {
        guard case .url(let url) = target else { return }
        // `paseo:` is registered only by the installed desktop app, so this can
        // fail. A menu row that silently does nothing reads as a broken app.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.report(
                    title: "Paseo Icon — could not open Paseo",
                    detail: "\(url.absoluteString)\n\n\(errorText(error))\n\nInstall the Paseo desktop app to open agents from the menu bar."
                )
            }
        }
    }

    private func report(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    /// `~/Library/Application Support`, the directory the Paseo app stores its
    /// Chromium profile under.
    nonisolated static func applicationSupportDirectory() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
    }
}
