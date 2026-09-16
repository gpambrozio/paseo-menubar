public enum SnappyError: Error, Equatable {
    case truncated
    case badOffset
    case lengthMismatch(expected: Int, actual: Int)

    public var message: String {
        switch self {
        case .truncated: "snappy block ended mid-token"
        case .badOffset: "snappy copy reaches before the start of its output"
        case .lengthMismatch(let expected, let actual):
            "snappy block declared \(expected) bytes and produced \(actual)"
        }
    }
}

/// Decoder for the raw snappy format LevelDB stores its compressed blocks in
/// (no framing, no CRC: the block trailer's CRC32C covers the compressed
/// bytes). Hand-written rather than a dependency for the same reason the
/// LevelDB reader is: the whole parser stays plain Swift with nothing to link.
public enum Snappy {
    public static func uncompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        let bytes = Array(input)
        var pos = 0
        // Preamble: the uncompressed length as a varint.
        var expected = 0
        var shift = 0
        while true {
            guard pos < bytes.count else { throw SnappyError.truncated }
            let byte = bytes[pos]
            pos += 1
            expected |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw SnappyError.truncated }
        }
        var out: [UInt8] = []
        out.reserveCapacity(expected)

        while pos < bytes.count {
            let tag = bytes[pos]
            pos += 1
            switch tag & 0x03 {
            case 0:
                // Literal. Lengths up to 60 ride in the tag; longer ones use
                // 1 to 4 trailing little-endian bytes.
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard pos + extra <= bytes.count else { throw SnappyError.truncated }
                    length = 0
                    for i in 0..<extra { length |= Int(bytes[pos + i]) << (8 * i) }
                    pos += extra
                }
                length += 1
                guard pos + length <= bytes.count else { throw SnappyError.truncated }
                out.append(contentsOf: bytes[pos..<(pos + length)])
                pos += length
            case 1:
                // Copy, 1-byte offset: length 4 to 11, offset 11 bits.
                guard pos < bytes.count else { throw SnappyError.truncated }
                let length = 4 + Int((tag >> 2) & 0x07)
                let offset = (Int(tag >> 5) << 8) | Int(bytes[pos])
                pos += 1
                try copy(into: &out, offset: offset, length: length)
            case 2:
                guard pos + 2 <= bytes.count else { throw SnappyError.truncated }
                let length = Int(tag >> 2) + 1
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
                pos += 2
                try copy(into: &out, offset: offset, length: length)
            default:
                guard pos + 4 <= bytes.count else { throw SnappyError.truncated }
                let length = Int(tag >> 2) + 1
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
                pos += 4
                try copy(into: &out, offset: offset, length: length)
            }
        }
        guard out.count == expected else {
            throw SnappyError.lengthMismatch(expected: expected, actual: out.count)
        }
        return out
    }

    /// A copy may overlap its own output (offset 1 repeats a byte), so it is
    /// appended one byte at a time rather than as a range.
    private static func copy(into out: inout [UInt8], offset: Int, length: Int) throws {
        guard offset > 0, offset <= out.count else { throw SnappyError.badOffset }
        let start = out.count - offset
        for i in 0..<length {
            out.append(out[start + i])
        }
    }
}
