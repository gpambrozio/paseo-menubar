import AppKit
import SwiftUI

/// The menu bar app. This preview build shows a static item with a Quit entry;
/// hosts, rows, and the count arrive with later plans.
@main
struct PaseoIconApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            Text("Paseo Icon (native preview)")
            Divider()
            Button("Quit Paseo Icon") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "circle.dashed")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon; this app is the menu bar item. The bundled build sets
        // LSUIElement too, but `swift run` has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
