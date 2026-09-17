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

    /// The rows' own height, reported by the rows. It decides one thing: which
    /// of the two layouts below the panel is in. Nothing reads it as a
    /// measurement, so being a point out near the boundary picks a branch that
    /// is correct either way.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let overflows = contentHeight > MenuMetrics.maxHeight
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.vertical, MenuMetrics.outerPadding)
            // Measured inside the scroll view, where the rows are laid out at
            // their natural height whichever branch is in force. Measuring the
            // scroll view instead would make the two branches feed each other:
            // hug reports the content, clamp reports the cap, and the panel
            // flips between them forever.
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: MenuMetrics.width)
        // Collapsing a row makes the content shorter; nothing else makes the
        // panel follow it.
        .background(PanelResizer(items: items))
        // Two layouts, and the menu needs both.
        //
        // `fixedSize` is what keeps a short menu from opening as an empty
        // sliver: a window-style `MenuBarExtra` sizes its panel by asking what
        // fits under a proposal with no height in it, and a `ScrollView`
        // answers zero, because it will be any height and so asks for none.
        //
        // But `fixedSize` lays the scroll view out at its *content's* height,
        // and `maxHeight` then clamps only the size the panel is told. Past the
        // cap those two disagree and the rows lose: at 60 rows this view
        // measured a 560pt panel with a 1566pt scroll view inside it, so rows hang off the
        // window with nothing to scroll — the section headings at the top and
        // every footer row, Quit included, out of reach. A tray with nothing
        // left to click.
        //
        // So past the cap the scroll view is given the cap as a real height
        // instead, which lays it out at 560 and lets it scroll. `maxHeight`
        // stays as the backstop for the first pass, before the rows have
        // reported anything.
        .fixedSize(horizontal: false, vertical: !overflows)
        .frame(height: overflows ? MenuMetrics.maxHeight : nil)
        .frame(maxHeight: MenuMetrics.maxHeight)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
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
            MenuActionRow { coordinator.openWorkspace(row); dismiss() } label: { hovering in
                Self.workspaceText(label: label, host: MenuModel.rowHostSuffix(row), hovering: hovering)
            }

        case .overflow(_, let label):
            // The capped rows are only reachable in the app.
            MenuActionRow { coordinator.openApp(); dismiss() } label: { _ in
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
            //
            // Closed first, and the alert raised on the next turn. The alert is
            // modal and runs its own loop, so raising it inline would spin that
            // loop with this panel still open and key — and the panel would
            // then only close once the alert was dismissed. Under menu style
            // the `NSMenu` had already closed by the time an action ran, so
            // ordering did not matter; here it does.
            MenuActionRow {
                dismiss()
                Task { @MainActor in coordinator.showConfigError(detail) }
            } label: { _ in
                Text("Configuration error").font(MenuMetrics.font)
            }

        case .hostsSummary(let label, let expanded):
            // The one row that changes the menu instead of leaving it: no
            // `dismiss()`, because the result is the rows it just revealed.
            MenuActionRow(action: toggleHosts) { _ in
                HStack(spacing: MenuMetrics.iconSpacing) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        // A fixed width, so the label does not shift sideways
                        // by a point when the chevron turns.
                        .frame(width: 10, alignment: .center)
                    Text(label).font(MenuMetrics.font)
                }
            }
            // The state is the row's value; the hint says what activating it
            // does. It is already a button, so it does not need to say so.
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the list of hosts" : "Shows the list of hosts")

        case .hostStatus(let hostId, let label, let retryable):
            if retryable {
                MenuActionRow { coordinator.retryHost(hostId); dismiss() } label: { _ in
                    Text(label).font(MenuMetrics.font).padding(.leading, MenuMetrics.hostIndent)
                }
            } else {
                MenuStaticRow {
                    Text(label).font(MenuMetrics.font).foregroundStyle(.secondary)
                        .padding(.leading, MenuMetrics.hostIndent)
                }
            }

        case .openApp:
            MenuActionRow { coordinator.openApp(); dismiss() } label: { _ in
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
            MenuActionRow { coordinator.quit() } label: { _ in
                Text("Quit Paseo Icon").font(MenuMetrics.font)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// A workspace row: the workspace and its project at full strength, then
    /// the host that it is on, smaller and quieter. One `Text` rather than an
    /// `HStack` of two, so the row wraps as one sentence and reads to VoiceOver
    /// as one string.
    private static func workspaceText(label: String, host: String?, hovering: Bool) -> Text {
        let workspace = Text(label).font(MenuMetrics.font)
        guard let host else { return workspace }
        // The highlight paints the row white. A secondary grey run on top of
        // the accent colour reads as unreadable rather than as quiet, so under
        // the pointer the host stays the row's own colour, just weaker.
        let quiet: AnyShapeStyle = hovering
            ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor).opacity(0.75))
            : AnyShapeStyle(.secondary)
        return workspace + Text(host).font(MenuMetrics.hostFont).foregroundStyle(quiet)
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

/// How tall the rows are, reported up from inside the scroll view.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    /// Two points under the menu font, for the host a workspace row ends with.
    static let hostFont = Font(NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2))
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
    /// Handed the pointer state, because a run of text that is deliberately
    /// quiet has to be quiet against the highlight too, and only this view
    /// knows whether the pointer is here.
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuMetrics.rowInset)
                .padding(.vertical, MenuMetrics.rowSpacing)
                // Without this the row is only clickable where its text is,
                // and the gap to the right of a short label does nothing.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The system's own selection colours, not the accent colour and white.
        // These are what a menu row drew itself with, so they follow the user's
        // Highlight colour and stay legible against a light accent or graphite,
        // where white on `accentColor` does not.
        .foregroundStyle(hovering ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius)
                .fill(hovering ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
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
