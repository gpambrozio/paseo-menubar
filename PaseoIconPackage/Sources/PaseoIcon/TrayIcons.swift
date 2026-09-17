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
        guard let url = Bundle.module.url(forResource: "\(name)Template", withExtension: "png", subdirectory: "TrayIcons"),
              let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else {
            throw TrayIconError.missing(name)
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
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
