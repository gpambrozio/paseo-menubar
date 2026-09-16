import Foundation
@testable import PaseoIconCore

/// A filesystem that passes through to the real one except for paths a test
/// has queued behaviours for. Each path's queue is consumed front to back and
/// then sticks on its last entry, so "throw once, then succeed" and "always
/// throw" are both expressible. This is the seam a test uses to make one
/// specific file vanish between the two scans `readValue` can run.
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    enum Behavior {
        case vanish
        case fail(any Error)
        case bytes([UInt8])
    }

    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var queues: [String: [Behavior]] = [:]
    private(set) var readCounts: [String: Int] = [:]

    func queue(_ path: String, _ behaviors: [Behavior]) {
        lock.lock()
        defer { lock.unlock() }
        queues[path] = behaviors
    }

    func listDirectory(_ path: String) throws -> [String] {
        try real.listDirectory(path)
    }

    func readFile(_ path: String) throws -> [UInt8] {
        lock.lock()
        readCounts[path, default: 0] += 1
        var behavior: Behavior?
        if var queue = queues[path], !queue.isEmpty {
            behavior = queue.count > 1 ? queue.removeFirst() : queue[0]
            queues[path] = queue
        }
        lock.unlock()

        switch behavior {
        case .vanish: throw FileReadError.notFound(path: path)
        case .fail(let error): throw FileReadError.other(path: path, underlying: error)
        case .bytes(let bytes): return bytes
        case nil: return try real.readFile(path)
        }
    }
}

/// A POSIX error that is not ENOENT, for the "damage, not migration" case.
struct PermissionDenied: Error, CustomStringConvertible {
    var description: String { "EACCES" }
}
