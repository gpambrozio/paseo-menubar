import AppKit
import PaseoIconCore
import SwiftUI

/// The menu bar item itself: the bucket's glyph, plus the count when there is
/// one. `MenuBarExtra`'s label does not respect colour or layout modifiers
/// directly, so the composed view is rasterized through `ImageRenderer` and
/// handed over as an image.
///
/// The image stays a template, so it inverts with the menu bar the way the
/// Electron build's template icon and adjacent title text both did. Colour is
/// possible here in a way it was not under Electron; parity comes first.
struct MenuBarLabel: View {
    let icon: TrayIconState
    let count: Int

    var body: some View {
        if let image = Self.render(icon: icon, count: count) {
            Image(nsImage: image)
        } else {
            // Only reachable if the icons are missing, which `preflight`
            // already refuses to start on.
            Image(systemName: "circle.dashed")
        }
    }

    @MainActor
    private static func render(icon: TrayIconState, count: Int) -> NSImage? {
        guard let glyph = try? TrayIcons.image(for: icon) else { return nil }
        if count == 0 { return glyph }

        let content = HStack(spacing: 3) {
            Image(nsImage: glyph)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return glyph }
        image.isTemplate = true
        return image
    }
}
