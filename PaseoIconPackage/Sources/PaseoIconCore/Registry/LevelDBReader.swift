import Foundation

/// The value the newest surviving record carried, and whether anything in
/// the directory was unreadable while working it out. The two travel
/// together: a damaged file may have held the newest write, in which case
/// the value here is a superseded one, and the caller decides.
public struct LevelDBReadResult: Equatable, Sendable {
    /// Nil when the key is absent. Never nil alongside a `parseFailure`.
    public let value: [UInt8]?
    /// Detail for the error row when part of the database was unreadable.
    public let parseFailure: String?
}

/// "No value" plus trouble: absence is indistinguishable from a file that
/// could not be read or was never seen, so the read fails rather than
/// reporting the key as gone.
public struct LevelDBReadError: MessageError {
    public let message: String
    public let cause: (any Error)?
}

/// A LevelDB directory: newest sequence wins. Reads one key without taking
/// the database lock, scanning every `.ldb`/`.sst`/`.log` and taking the
/// highest sequence, which is correct by construction provided the scan saw
/// every live file; re-listing when a file vanished is what guarantees that.
public enum LevelDBReader {
    /// How many times one read may list the directory. Chromium can compact
    /// more than once while we work.
    static let maxScans = 3

    private struct ScanResult {
        var winner: InternalRecord?
        var relevantCount = 0
        var parseSkipCount = 0
        var vanishedCount = 0
        var firstParseError: (any Error)?
    }

    public static func readValue(directory: String, userKey: [UInt8], fileSystem: any FileSystem = LocalFileSystem()) throws -> LevelDBReadResult {
        var result = try scan(directory, userKey, fileSystem)
        var scans = 1
        while scans < maxScans, result.vanishedCount > 0 {
            result = try scan(directory, userKey, fileSystem)
            scans += 1
        }

        let value: [UInt8]? = if let winner = result.winner, !winner.isDeletion { winner.value } else { nil }

        let damaged = result.parseSkipCount > 0
        let unsettled = result.vanishedCount > 0
        if damaged || unsettled {
            let detail = damaged
                ? "Could not read \(result.parseSkipCount) of \(result.relevantCount) LevelDB file(s) in \(directory)"
                : "\(directory) kept changing across \(maxScans) listings"
            guard let value else {
                throw LevelDBReadError(message: "\(detail); the key's value could not be determined", cause: result.firstParseError)
            }
            return LevelDBReadResult(value: value, parseFailure: "\(detail); the host list may be out of date")
        }
        return LevelDBReadResult(value: value, parseFailure: nil)
    }

    /// One pass: list the directory and best-effort read every table and log
    /// in that listing. A file gone by read time (`notFound`) means the
    /// listing was stale; any other read error, or a parse error, is damage.
    /// An unsupported compression type means the format moved under us and
    /// every file is suspect, so that one propagates.
    private static func scan(_ directory: String, _ userKey: [UInt8], _ fileSystem: any FileSystem) throws -> ScanResult {
        let names = try fileSystem.listDirectory(directory)
        var result = ScanResult()

        for name in names {
            // `.sst` is LevelDB's pre-2013 name for the same table format.
            let isTable = name.hasSuffix(".ldb") || name.hasSuffix(".sst")
            let isLog = name.hasSuffix(".log")
            guard isTable || isLog else { continue }
            result.relevantCount += 1

            let bytes: [UInt8]
            do {
                bytes = try fileSystem.readFile((directory as NSString).appendingPathComponent(name))
            } catch FileReadError.notFound {
                result.vanishedCount += 1
                continue
            } catch {
                result.parseSkipCount += 1
                if result.firstParseError == nil { result.firstParseError = error }
                continue
            }

            let records: [InternalRecord]
            do {
                if isTable {
                    records = try SSTable.find(in: bytes, userKey: userKey)
                } else {
                    let log = try WAL.find(in: bytes, userKey: userKey)
                    records = log.records
                    if log.droppedFragments > 0 {
                        result.parseSkipCount += 1
                        if result.firstParseError == nil {
                            result.firstParseError = LevelDBReadError(
                                message: "Discarded \(log.droppedFragments) corrupt record fragment(s) in \(name)",
                                cause: nil
                            )
                        }
                    }
                }
            } catch SSTableError.unsupportedCompression(let type) {
                throw SSTableError.unsupportedCompression(type)
            } catch {
                result.parseSkipCount += 1
                if result.firstParseError == nil { result.firstParseError = error }
                continue
            }

            for record in records where result.winner == nil || record.sequence > result.winner!.sequence {
                result.winner = record
            }
        }
        return result
    }
}
