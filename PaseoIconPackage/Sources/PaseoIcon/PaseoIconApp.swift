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
            MenuBarLabel(icon: coordinator.model.icon, count: coordinator.model.count)
                .task { coordinator.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
