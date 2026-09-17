import AppKit
import PaseoIconCore
import SwiftUI

/// The menu bar app. No window is ever created: `MenuBarExtra` in menu style
/// is the whole interface, and every action lives in the menu.
@main
struct PaseoIconApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                items: MenuModel.build(coordinator.model, loginItemEnabled: coordinator.loginItemEnabled),
                coordinator: coordinator
            )
        } label: {
            MenuBarLabel(
                icon: coordinator.model.icon,
                count: coordinator.model.count,
                needsAttention: coordinator.model.needsAttention
            )
                .task {
                    // The delegate is created by AppKit and cannot reach the
                    // scene's state on its own; this is the one place both
                    // exist. Weakly held there, so nothing is kept alive by it.
                    appDelegate.coordinator = coordinator
                    coordinator.start()
                }
        }
        // Window style, stated rather than left to `.automatic`. The panel is
        // the whole interface: menu style makes every row an `NSMenuItem`,
        // which drops view modifiers and draws a non-clickable row in the
        // disabled grey, so a section heading could not be given the weight it
        // needed. This is still not a free-standing window — the panel belongs
        // to the menu bar item and closes when it resigns key.
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene once both exist. Quitting from the menu calls `stop()`
    /// itself; logging out and shutting down bypass that row, and the Electron
    /// build caught them with `before-quit`. A raw `SIGTERM` still gets neither,
    /// because AppKit installs no handler for it — the sockets close with the
    /// process instead.
    weak var coordinator: AppCoordinator?

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon; this app is the menu bar item. The bundle sets
        // LSUIElement too, but `swift run` has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)

        // A second copy would put a second item in the menu bar, both reading
        // the same registry. The bundle id is the lock.
        if isAlreadyRunning() {
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            try TrayIcons.preflight()
        } catch {
            // No icon means no visible item at all: nothing to click, nothing
            // to quit. Say so and exit rather than running invisibly.
            let alert = NSAlert()
            alert.messageText = "Paseo Icon — failed to start"
            alert.informativeText = errorText(error)
            // An accessory app is not frontmost, so without this the alert can
            // open behind every other window while the main thread sits in its
            // modal loop: no menu bar item, nothing to click, nothing to quit.
            NSApp.activate()
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func isAlreadyRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}
