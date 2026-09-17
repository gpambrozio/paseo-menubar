import Foundation

public enum LocalStorageError: Error, Equatable {
    case emptyValue
    case unknownEncodingTag(UInt8)
    case undecodable

    public var message: String {
        switch self {
        case .emptyValue: "localStorage value is empty"
        case .unknownEncodingTag(let tag): "Unknown localStorage value encoding tag \(tag)"
        case .undecodable: "localStorage value is not valid text"
        }
    }
}

/// Chromium's localStorage record layout, as stored in its LevelDB.
///
/// Keys and values use the same string encoding: a leading tag byte, 0x01 for
/// Latin1 when every code unit fits in a byte and 0x00 for UTF-16LE otherwise,
/// followed by the bytes. A record's key is `_<origin>` + 0x00 + the encoded
/// key; the byte after the 0x00 is the key's own encoding tag, which is why
/// an ASCII key reads as 0x00 0x01.
public enum LocalStorage {
    private static let latin1Tag: UInt8 = 0x01
    private static let utf16leTag: UInt8 = 0x00
    private static let originTerminator: UInt8 = 0x00

    public static func key(origin: String, key: String) -> [UInt8] {
        var bytes = Array("_\(origin)".utf8)
        bytes.append(originTerminator)
        bytes.append(contentsOf: encodeString(key))
        return bytes
    }

    public static func decodeValue(_ value: [UInt8]) throws -> String {
        guard let tag = value.first else { throw LocalStorageError.emptyValue }
        let body = Array(value.dropFirst())
        switch tag {
        case latin1Tag:
            guard let text = String(bytes: body, encoding: .isoLatin1) else { throw LocalStorageError.undecodable }
            return text
        case utf16leTag:
            guard let text = String(bytes: body, encoding: .utf16LittleEndian) else { throw LocalStorageError.undecodable }
            return text
        default:
            throw LocalStorageError.unknownEncodingTag(tag)
        }
    }

    private static func encodeString(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        if units.allSatisfy({ $0 <= 0xff }) {
            return [latin1Tag] + units.map { UInt8($0) }
        }
        var bytes: [UInt8] = [utf16leTag]
        for unit in units {
            bytes.append(UInt8(unit & 0xff))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }
}
