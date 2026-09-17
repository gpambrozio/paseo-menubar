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

            case .note(_, let text):
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
                // A Toggle, not a Button with a tick in its title: inside a
                // menu SwiftUI draws it in the checkmark column, which is what
                // Electron's `type: "checkbox"` gave, and it reports a checked
                // state to VoiceOver where a prefixed character reports none.
                Toggle("Start at login", isOn: Binding(
                    get: { enabled },
                    set: { coordinator.setLoginItem($0) }
                ))

            case .quit:
                Button("Quit Paseo Icon") { coordinator.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
