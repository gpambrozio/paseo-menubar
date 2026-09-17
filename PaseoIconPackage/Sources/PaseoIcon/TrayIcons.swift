import AppKit
import PaseoIconCore

/// The five bucket glyphs, as template images so they invert with the menu
/// bar. They are the same PNGs `npm run icons` rasterizes for the Electron
/// build, copied into this target's resources, so both apps show the same
/// marks rather than two vocabularies for one set of states.
@MainActor
enum TrayIcons {
    private static var cache: [WorkspaceStateBucket: NSImage] = [:]

    /// A missing file yields an empty image rather than an error, and an empty
    /// image is a status item with no visible icon: no way to open the menu,
    /// no way to quit. The icons are generated rather than committed, so this
    /// is reachable from a build that skipped `npm run icons`.
    static func image(for bucket: WorkspaceStateBucket) throws -> NSImage {
        if let cached = cache[bucket] { return cached }
        let name = TrayViewModelBuilder.iconNames[bucket] ?? bucket.rawValue
        // Both rasterizations, not just the 1x one. `NSImage(contentsOf:)` on a
        // single file yields a single representation, so a Retina menu bar
        // would draw 16px art in a 32px box for every user; Electron's
        // `nativeImage.createFromPath` picked the `@2x` sibling up by itself
        // and nothing here does. The PNGs also carry a 288-DPI pHYs chunk, so
        // each representation loads claiming to be 4pt square — pinning both to
        // the 16pt box is what makes AppKit choose by scale rather than size.
        let box = NSSize(width: 16, height: 16)
        let image = NSImage(size: box)
        for suffix in ["", "@2x"] {
            guard let url = Bundle.module.url(forResource: "\(name)Template\(suffix)", withExtension: "png", subdirectory: "TrayIcons"),
                  let rep = NSImageRep(contentsOf: url) else { continue }
            rep.size = box
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty, image.isValid else {
            throw TrayIconError.missing(name)
        }
        image.isTemplate = true
        cache[bucket] = image
        return image
    }

    /// Loads every bucket once, so a build missing its icons fails at launch
    /// with a name rather than showing a blank item.
    static func preflight() throws {
        for bucket in TrayViewModelBuilder.sectionOrder { _ = try image(for: bucket) }
    }
}

enum TrayIconError: MessageError {
    case missing(String)

    var message: String {
        switch self {
        case .missing(let name): "Missing tray icon: \(name)Template.png. Run `npm run icons`."
        }
    }
}
