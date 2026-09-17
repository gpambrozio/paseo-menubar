import AppKit
import PaseoIconCore
import SwiftUI

/// Renders the menu `MenuModel` decided on. Nothing here chooses what the menu
/// contains: every row, label, and ordering rule lives in the core, which is
/// what lets the whole menu be tested without a menu bar.
///
/// This is a panel rather than an `NSMenu`: `MenuBarExtra` is in window style,
/// so every row is a real SwiftUI view. An `NSMenu` row is an `NSMenuItem`,
/// which drops the view modifiers on the way in and draws a non-clickable row
/// in the disabled grey no matter what colour the title asks for — which is
/// what the section headings ran into.
struct MenuContent: View {
    let items: [MenuItem]
    let coordinator: AppCoordinator
    /// Shows or hides the per-host rows. The state lives in the scene, so it
    /// survives the panel closing; which rows exist is still `MenuModel`'s call.
    let toggleHosts: () -> Void

    /// Closes the panel. Actions that take the user elsewhere call it, the way
    /// clicking a menu row used to close the menu. Opening Paseo also makes the
    /// panel resign key, which closes it on its own, so this is the belt to
    /// that braces — it is what handles the rows that open nothing.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.vertical, MenuMetrics.outerPadding)
        }
        .frame(width: MenuMetrics.width)
        // Collapsing a row makes the content shorter; nothing else makes the
        // panel follow it.
        .background(PanelResizer(items: items))
        // Load-bearing, and the reason the panel first came up as an empty
        // sliver. A window-style `MenuBarExtra` sizes its panel by asking the
        // hosting controller what fits under a proposal with no height in it,
        // and a `ScrollView` answers zero — it will happily be any height, so
        // it asks for none. `fixedSize` vertically makes it answer with its
        // content's height instead, and the cap below clamps that; measured at
        // 144pt for six rows and 520 for sixty, where the bare `ScrollView`
        // measured 0 for both.
        .fixedSize(horizontal: false, vertical: true)
        // The content decides the height until it reaches the cap, after which
        // the panel scrolls rather than growing past the screen. A menu did
        // this by itself; a window does not.
        .frame(maxHeight: MenuMetrics.maxHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func row(_ item: MenuItem) -> some View {
        switch item {
        case .sectionHeading(let bucket, let label):
            // The heading the menu could not draw: full-strength label colour
            // and the menu font at bold weight, matching the sidebar, which
            // shows one glyph per section.
            MenuStaticRow {
                HStack(spacing: MenuMetrics.iconSpacing) {
                    glyph(bucket)
                    Text(label)
                        .font(MenuMetrics.boldFont)
                        .foregroundStyle(.primary)
                }
            }

        case .workspace(let row, let label):
            MenuActionRow { coordinator.openWorkspace(row); dismiss() } label: {
                Text(label).font(MenuMetrics.font)
            }

        case .overflow(_, let label):
            // The capped rows are only reachable in the app.
            MenuActionRow { coordinator.openApp(); dismiss() } label: {
                Text(label).font(MenuMetrics.font)
            }

        case .separator:
            Divider().padding(.horizontal, MenuMetrics.dividerInset).padding(.vertical, 4)

        case .note(_, let text):
            MenuStaticRow {
                Text(text).font(MenuMetrics.font).foregroundStyle(.secondary)
            }

        case .configError(let detail):
            // The fix for every one of these is in the Paseo app.
            MenuActionRow { coordinator.showConfigError(detail); dismiss() } label: {
                Text("Configuration error").font(MenuMetrics.font)
            }

        case .hostsSummary(let label, let expanded):
            // The one row that changes the menu instead of leaving it: no
            // `dismiss()`, because the result is the rows it just revealed.
            MenuActionRow(action: toggleHosts) {
                HStack(spacing: MenuMetrics.iconSpacing) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        // A fixed width, so the label does not shift sideways
                        // by a point when the chevron turns.
                        .frame(width: 10, alignment: .center)
                    Text(label).font(MenuMetrics.font)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Hides the list of hosts" : "Shows the list of hosts")

        case .hostStatus(let hostId, let label, let retryable):
            if retryable {
                MenuActionRow { coordinator.retryHost(hostId); dismiss() } label: {
                    Text(label).font(MenuMetrics.font).padding(.leading, MenuMetrics.hostIndent)
                }
            } else {
                MenuStaticRow {
                    Text(label).font(MenuMetrics.font).foregroundStyle(.secondary)
                        .padding(.leading, MenuMetrics.hostIndent)
                }
            }

        case .openApp:
            MenuActionRow { coordinator.openApp(); dismiss() } label: {
                Text("Open Paseo").font(MenuMetrics.font)
            }

        case .loginItem(let enabled):
            // A Toggle, not a row with a tick in its title: it reports a
            // checked state to VoiceOver where a prefixed character reports
            // none, which is the same reason the menu used one. The panel stays
            // open, because the switch is the result and there is nowhere to go.
            MenuStaticRow {
                Toggle("Start at login", isOn: Binding(
                    get: { enabled },
                    set: { coordinator.setLoginItem($0) }
                ))
                .toggleStyle(.checkbox)
                .font(MenuMetrics.font)
            }

        case .quit:
            MenuActionRow { coordinator.quit() } label: {
                Text("Quit Paseo Icon").font(MenuMetrics.font)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private func glyph(_ bucket: WorkspaceStateBucket) -> some View {
        if let image = try? TrayIcons.image(for: bucket) {
            // Template, so it takes the row's own colour: the label colour
            // normally, white while the row is highlighted.
            Image(nsImage: image).renderingMode(.template)
        }
    }
}

/// The measurements every row shares. The font is the menu's own rather than
/// `NSFont.systemFontSize`, which is a different size — this panel replaced a
/// menu and should not quietly change type size along with it.
enum MenuMetrics {
    /// Wide enough for a real row rather than a guess: the longest row in the
    /// author's own menu — workspace, project, and host — measures 437pt in the
    /// menu font, and the insets add 32. A row longer than this wraps rather
    /// than truncating, because a clipped workspace name is information the
    /// menu used to widen itself to show.
    static let width: CGFloat = 480
    static let maxHeight: CGFloat = 560
    static let outerPadding: CGFloat = 6
    static let rowInset: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let iconSpacing: CGFloat = 6
    static let dividerInset: CGFloat = 12
    /// Lines a host row up with the summary's label rather than its chevron, so
    /// the rows read as belonging to the row that revealed them.
    static let hostIndent: CGFloat = 16
    static let cornerRadius: CGFloat = 5

    static let font = Font(NSFont.menuFont(ofSize: 0))
    static let boldFont = Font(NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize))
}

/// Shrinks the panel back after its content does.
///
/// A window-style `MenuBarExtra` grows its panel when the content grows and
/// never shrinks it again. Collapsing the host rows left the panel at its
/// expanded height with the menu centred inside it — the screenshot that sent
/// this code looking was 480x207 of menu floating in a 480x231 panel, 12pt of
/// nothing above and below.
///
/// What the panel reports about itself, logged from inside a running build:
/// the window is `MenuBarExtraWindow`, its content view is
/// `MenuBarExtraHostingView`, and that view's `fittingSize` is `(0, 0)` — it
/// answers no question about how big the menu is. The view planted here does:
/// it backs the rows, so after layout its own `bounds` is exactly the height
/// the panel should be. The first attempt at this asked the content view and
/// got zero, which is why nothing moved.
///
/// Only shrinking is handled. Growing already works, and setting a frame
/// SwiftUI is also setting would be two things fighting over one window.
struct PanelResizer: NSViewRepresentable {
    /// Not read. It is here so SwiftUI runs `updateNSView` whenever the rows
    /// change, which is the only moment the panel can be wrong.
    let items: [MenuItem]

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // Next turn of the main actor, and a layout pass before measuring. Both
        // are load-bearing: when this runs, `view` is still the height of the
        // rows that are going away, and only laying the window out brings it to
        // the new one.
        Task { @MainActor in
            guard let window = view.window, let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            guard let frame = Self.shrunkFrame(from: window.frame, contentHeight: view.bounds.height, in: window) else { return }
            window.setFrame(frame, display: true)
        }
    }

    /// The frame a panel should take to fit content of `contentHeight`, or nil
    /// when it already fits or would have to grow.
    ///
    /// The top edge is preserved, not the origin: the panel hangs from the menu
    /// bar item, so a shrink that kept `origin.y` would drop the whole panel
    /// down the screen. The logged frames agree — expanding moved the panel from
    /// `(1070, 841, 480, 207)` to `(1070, 817, 480, 231)`, holding its top edge
    /// at 1048, and this returns the first of those from the second.
    @MainActor
    static func shrunkFrame(from frame: NSRect, contentHeight: CGFloat, in window: NSWindow) -> NSRect? {
        guard contentHeight > 0 else { return nil }
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: contentHeight)).height
        guard frame.height - target > 0.5 else { return nil }
        return NSRect(x: frame.minX, y: frame.maxY - target, width: frame.width, height: target)
    }
}

/// A row that does something. Full-width hit area and a highlight under the
/// pointer, which is what a menu row gave for free and a panel does not.
private struct MenuActionRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuMetrics.rowInset)
                .padding(.vertical, MenuMetrics.rowSpacing)
                // Without this the row is only clickable where its text is,
                // and the gap to the right of a short label does nothing.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius)
                .fill(hovering ? Color.accentColor : .clear)
        )
        .padding(.horizontal, MenuMetrics.outerPadding)
        .onHover { hovering = $0 }
    }
}

/// A row that only says something: the same metrics, no highlight, no action.
private struct MenuStaticRow<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.rowInset)
            .padding(.vertical, MenuMetrics.rowSpacing)
            .padding(.horizontal, MenuMetrics.outerPadding)
    }
}
