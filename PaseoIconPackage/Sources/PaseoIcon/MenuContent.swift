import PaseoIconCore
import SwiftUI

/// Renders the menu `MenuModel` decided on. Nothing here chooses what the menu
/// contains: every row, label, and ordering rule lives in the core, which is
/// what lets the whole menu be tested without a menu bar.
struct MenuContent: View {
    let items: [MenuItem]
    let coordinator: AppCoordinator

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .sectionHeading(let bucket, let label):
                // A disabled heading carrying its bucket's glyph, matching the
                // sidebar, which shows one per section.
                Label {
                    Text(label)
                } icon: {
                    if let image = try? TrayIcons.image(for: bucket) { Image(nsImage: image) }
                }
                .disabled(true)

            case .workspace(let row, let label):
                Button(label) { coordinator.openWorkspace(row) }

            case .overflow(_, let label):
                // The capped rows are only reachable in the app.
                Button(label) { coordinator.openApp() }

            case .separator:
                Divider()

            case .note(let text):
                Text(text)

            case .configError(let detail):
                // The fix for every one of these is in the Paseo app.
                Button("Configuration error") { coordinator.showConfigError(detail) }

            case .hostStatus(let hostId, let label, let retryable):
                if retryable {
                    Button(label) { coordinator.retryHost(hostId) }
                } else {
                    Text(label)
                }

            case .openApp:
                Button("Open Paseo") { coordinator.openApp() }

            case .loginItem(let enabled):
                Button(enabled ? "✓ Start at login" : "Start at login") {
                    coordinator.setLoginItem(!enabled)
                }

            case .quit:
                Button("Quit Paseo Icon") { coordinator.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
