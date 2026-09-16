import Foundation

/// One record as LevelDB stores it: a user key, the sequence number that
/// orders it against every other write, and whether it is a deletion.
public struct InternalRecord: Equatable, Sendable {
    public let userKey: [UInt8]
    public let sequence: UInt64
    public let isDeletion: Bool
    public let value: [UInt8]

    public init(userKey: [UInt8], sequence: UInt64, isDeletion: Bool, value: [UInt8]) {
        self.userKey = userKey
        self.sequence = sequence
        self.isDeletion = isDeletion
        self.value = value
    }
}

public enum SSTableError: Error, Equatable {
    case tooShort
    case badMagic
    case blockPastEnd
    /// Reading while Chromium writes: the checksum is the only thing between
    /// a torn read and silently wrong credentials.
    case checksumMismatch
    /// The compression byte is neither 0 (none) nor 1 (snappy). Distinguished
    /// from the generic parse errors so callers can tell "the storage format
    /// moved under us" apart from "this file is torn".
    case unsupportedCompression(UInt8)
    case blockTooShort
    case restartArrayOverrun
    case sharedPrefixOverrun
    case missingTrailer
    case corruptVarint

    public var message: String {
        switch self {
        case .tooShort: "file is too short to be an SSTable"
        case .badMagic: "not an SSTable: bad table magic"
        case .blockPastEnd: "block handle points past the end of the file"
        case .checksumMismatch: "LevelDB block failed its checksum"
        case .unsupportedCompression(let type):
            "Unsupported LevelDB compression type \(type). The Paseo app's storage format changed."
        case .blockTooShort: "block is too short"
        case .restartArrayOverrun: "block restart array overruns the block"
        case .sharedPrefixOverrun: "block entry shares more than it can"
        case .missingTrailer: "internal key is missing its trailer"
        case .corruptVarint: "block entry has a corrupt varint"
        }
    }
}

/// One LevelDB `.ldb`: footer, index block, data blocks, snappy.
public enum SSTable {
    private static let footerLength = 48
    private static let magicLow: UInt32 = 0x8b80_fb57
    private static let magicHigh: UInt32 = 0xdb47_7524
    private static let blockTrailerLength = 5 // 1 compression byte + 4 checksum bytes

    private struct BlockHandle {
        let offset: Int
        let size: Int
    }

    private struct BlockEntry {
        let key: [UInt8]
        let value: ArraySlice<UInt8>
    }

    /// Every record for `userKey` in one `.ldb`. Uses the index block to visit
    /// only the data blocks whose range can contain the key. A key can appear
    /// more than once with different sequence numbers, so this returns all
    /// matches and leaves the choice to the caller.
    public static func find(in file: [UInt8], userKey: [UInt8]) throws -> [InternalRecord] {
        let indexBlock = try readBlock(file, parseFooter(file))
        var found: [InternalRecord] = []

        for indexEntry in try blockEntries(indexBlock) {
            // An index entry's key is a separator >= every key in its block, so
            // a block can hold our key only if its separator is not below it.
            let separator = try splitInternalKey(indexEntry.key).userKey
            let cmp = Binary.compare(separator[...], userKey[...])
            if cmp < 0 { continue }

            let handleBytes = Array(indexEntry.value)
            let offset = try Binary.readVarint64(handleBytes, at: 0)
            let size = try Binary.readVarint64(handleBytes, at: offset.next)
            let dataBlock = try readBlock(file, BlockHandle(offset: Int(offset.value), size: Int(size.value)))

            for entry in try blockEntries(dataBlock) {
                let parsed = try splitInternalKey(entry.key)
                if Binary.compare(parsed.userKey[...], userKey[...]) != 0 { continue }
                found.append(InternalRecord(
                    userKey: parsed.userKey,
                    sequence: parsed.sequence,
                    isDeletion: parsed.isDeletion,
                    value: Array(entry.value)
                ))
            }

            // A separator strictly greater than the key means the next block
            // starts past it. An equal separator does not: a run of records
            // sharing one user key can straddle a block boundary.
            if cmp > 0 { break }
        }
        return found
    }

    private static func parseFooter(_ file: [UInt8]) throws -> BlockHandle {
        guard file.count >= footerLength else { throw SSTableError.tooShort }
        let footer = Array(file[(file.count - footerLength)...])
        guard Binary.readUInt32LE(footer, at: 40) == magicLow, Binary.readUInt32LE(footer, at: 44) == magicHigh else {
            throw SSTableError.badMagic
        }
        // metaindex handle first, then the index handle we actually want.
        var pos = 0
        pos = try Binary.readVarint64(footer, at: pos).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let offset = try Binary.readVarint64(footer, at: pos)
        let size = try Binary.readVarint64(footer, at: offset.next)
        return BlockHandle(offset: Int(offset.value), size: Int(size.value))
    }

    /// Reads one block, verifying its checksum before anything parses it.
    private static func readBlock(_ file: [UInt8], _ handle: BlockHandle) throws -> [UInt8] {
        let end = handle.offset + handle.size + blockTrailerLength
        guard handle.offset >= 0, handle.size >= 0, end <= file.count else { throw SSTableError.blockPastEnd }
        let contents = file[handle.offset..<(handle.offset + handle.size)]
        let compression = file[handle.offset + handle.size]
        let storedCrc = Binary.readUInt32LE(file, at: handle.offset + handle.size + 1)

        // The checksum covers the block contents plus the compression byte.
        let checked = file[handle.offset..<(handle.offset + handle.size + 1)]
        guard Binary.crc32c(checked) == Binary.unmaskCrc(storedCrc) else { throw SSTableError.checksumMismatch }

        switch compression {
        case 0: return Array(contents)
        case 1: return try Snappy.uncompress(contents)
        default: throw SSTableError.unsupportedCompression(compression)
        }
    }

    /// Walks a block's entries. Keys are prefix-compressed against the
    /// previous key, which is why this cannot seek and has to read forward.
    private static func blockEntries(_ block: [UInt8]) throws -> [BlockEntry] {
        guard block.count >= 4 else { throw SSTableError.blockTooShort }
        let restartCount = Int(Binary.readUInt32LE(block, at: block.count - 4))
        let entriesEnd = block.count - 4 - restartCount * 4
        guard entriesEnd >= 0 else { throw SSTableError.restartArrayOverrun }

        var entries: [BlockEntry] = []
        var pos = 0
        var previousKey: [UInt8] = []
        while pos < entriesEnd {
            let shared: (value: UInt32, next: Int)
            let nonShared: (value: UInt32, next: Int)
            let valueLength: (value: UInt32, next: Int)
            do {
                shared = try Binary.readVarint32(block, at: pos)
                nonShared = try Binary.readVarint32(block, at: shared.next)
                valueLength = try Binary.readVarint32(block, at: nonShared.next)
            } catch {
                throw SSTableError.corruptVarint
            }
            pos = valueLength.next

            guard Int(shared.value) <= previousKey.count else { throw SSTableError.sharedPrefixOverrun }
            let keyEnd = pos + Int(nonShared.value)
            let valueEnd = keyEnd + Int(valueLength.value)
            guard valueEnd <= block.count else { throw SSTableError.blockTooShort }
            var key = Array(previousKey[0..<Int(shared.value)])
            key.append(contentsOf: block[pos..<keyEnd])
            let value = block[keyEnd..<valueEnd]
            pos = valueEnd

            previousKey = key
            entries.append(BlockEntry(key: key, value: value))
        }
        return entries
    }

    /// Splits an internal key into its user key and 8-byte trailer of
    /// `(sequence << 8) | type`, stored little-endian. Type 0 is a deletion.
    private static func splitInternalKey(_ key: [UInt8]) throws -> (userKey: [UInt8], sequence: UInt64, isDeletion: Bool) {
        guard key.count >= 8 else { throw SSTableError.missingTrailer }
        let low = Binary.readUInt32LE(key, at: key.count - 8)
        let high = Binary.readUInt32LE(key, at: key.count - 4)
        // Sequence is 56 bits; the low byte of `low` is the record type.
        let sequence = (UInt64(high) << 24) | UInt64(low >> 8)
        return (Array(key[0..<(key.count - 8)]), sequence, (low & 0xff) == 0)
    }
}
