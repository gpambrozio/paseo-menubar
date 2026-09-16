import Foundation

/// Why a file could not be read. The two cases mean different things to the
/// directory reader: a file that is gone between listing and read migrated
/// under a compaction, while anything else is damage.
public enum FileReadError: Error, MessageError {
    case notFound(path: String)
    case other(path: String, underlying: any Error)

    public var message: String {
        switch self {
        case .notFound(let path): "ENOENT: no such file, \(path)"
        case .other(let path, let underlying): "\(errorText(underlying)) (\(path))"
        }
    }
}

/// The two filesystem calls the LevelDB reader makes, injected so tests can
/// make one specific file vanish or fail between two scans.
public protocol FileSystem: Sendable {
    func listDirectory(_ path: String) throws -> [String]
    func readFile(_ path: String) throws -> [UInt8]
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func listDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func readFile(_ path: String) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached]))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                throw FileReadError.notFound(path: path)
            }
            if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               posix.domain == NSPOSIXErrorDomain, posix.code == Int(ENOENT) {
                throw FileReadError.notFound(path: path)
            }
            throw FileReadError.other(path: path, underlying: error)
        }
    }
}
