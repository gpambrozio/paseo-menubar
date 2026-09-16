import Foundation

public enum BinaryError: Error, Equatable {
    /// The buffer ended inside a varint. Thrown rather than returning a partial
    /// value: every caller is parsing a file another process is actively
    /// writing, and a silently short read there is the difference between
    /// "retry" and "wrong credentials".
    case varintPastEnd(String)
    case varintTooLong(String)
}

/// Varint, checksum, and little-endian primitives for LevelDB's on-disk
/// formats. Knows nothing about LevelDB itself: both the SSTable reader and
/// the write-ahead-log reader need these, and keeping them separate is what
/// lets each of those be tested against its own format alone.
public enum Binary {
    public static func readVarint32(_ buf: [UInt8], at pos: Int) throws -> (value: UInt32, next: Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var cursor = pos
        while true {
            guard cursor >= 0, cursor < buf.count else {
                throw BinaryError.varintPastEnd("varint32 ran past end of buffer")
            }
            let byte = buf[cursor]
            cursor += 1
            result |= UInt32(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw BinaryError.varintTooLong("varint32 is longer than 5 bytes") }
        }
        return (result, cursor)
    }

    /// Block offsets and sizes are the only 64-bit varints read, and they are
    /// bounded by file size.
    public static func readVarint64(_ buf: [UInt8], at pos: Int) throws -> (value: UInt64, next: Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = pos
        while true {
            guard cursor >= 0, cursor < buf.count else {
                throw BinaryError.varintPastEnd("varint64 ran past end of buffer")
            }
            let byte = buf[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw BinaryError.varintTooLong("varint64 is longer than 10 bytes") }
        }
        return (result, cursor)
    }

    public static func readUInt16LE(_ buf: [UInt8], at pos: Int) -> UInt16 {
        UInt16(buf[pos]) | (UInt16(buf[pos + 1]) << 8)
    }

    public static func readUInt32LE(_ buf: [UInt8], at pos: Int) -> UInt32 {
        UInt32(buf[pos]) | (UInt32(buf[pos + 1]) << 8) | (UInt32(buf[pos + 2]) << 16) | (UInt32(buf[pos + 3]) << 24)
    }

    // CRC32C (Castagnoli), reversed polynomial. LevelDB uses this, not CRC32.
    private static let crc32cTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0x82f6_3b78 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32c(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = crc32cTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    public static func crc32c(_ bytes: [UInt8]) -> UInt32 { crc32c(bytes[...]) }

    private static let maskDelta: UInt32 = 0xa282_ead8

    /// LevelDB's CRC mask: stored checksums are rotated and offset so that a
    /// checksum never appears verbatim in the data it covers.
    public static func maskCrc(_ crc: UInt32) -> UInt32 {
        let rot = (crc >> 15) | (crc << 17)
        return rot &+ maskDelta
    }

    public static func unmaskCrc(_ masked: UInt32) -> UInt32 {
        let rot = masked &- maskDelta
        return (rot >> 17) | (rot << 15)
    }

    /// Unsigned bytewise comparison, a shorter prefix ordering first: the
    /// order LevelDB's default comparator and Node's `Buffer.compare` share.
    public static func compare(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex {
            if a[ia] != b[ib] { return a[ia] < b[ib] ? -1 : 1 }
            ia += 1
            ib += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }
}
