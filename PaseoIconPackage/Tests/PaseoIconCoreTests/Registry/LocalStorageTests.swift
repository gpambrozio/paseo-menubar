import Foundation
import Testing
@testable import PaseoIconCore

struct LocalStorageTests {
    @Test("frames the key the way Chromium stores it")
    func framesKey() {
        let key = LocalStorage.key(origin: "paseo://app", key: "@paseo:daemon-registry")
        // 0x00 terminates the origin; 0x01 is the key's own Latin1 encoding tag.
        #expect(key == Array("_paseo://app".utf8) + [0x00, 0x01] + Array("@paseo:daemon-registry".utf8))
    }

    @Test("tags a key that does not fit in Latin1 as UTF-16LE, as Chromium does")
    func utf16Key() {
        let key = LocalStorage.key(origin: "paseo://app", key: "☕")
        #expect(key == Array("_paseo://app".utf8) + [0x00, 0x00] + [0x15, 0x26])
    }

    @Test("decodes a Latin1-tagged value")
    func latin1() throws {
        #expect(try LocalStorage.decodeValue([0x01] + Array("hosts".utf8)) == "hosts")
    }

    @Test("preserves a non-ASCII byte through the Latin1 path")
    func latin1NonAscii() throws {
        // 0xE9 is `é` in Latin1 and an invalid lead byte in UTF-8.
        #expect(try LocalStorage.decodeValue([0x01, 0x63, 0x61, 0x66, 0xe9]) == "café")
    }

    @Test("decodes a UTF-16LE-tagged value")
    func utf16() throws {
        let body = "hosts".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        #expect(try LocalStorage.decodeValue([0x00] + body) == "hosts")
    }

    @Test("preserves non-ASCII characters through the UTF-16 path")
    func utf16NonAscii() throws {
        let body = "naïve ☕".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        #expect(try LocalStorage.decodeValue([0x00] + body) == "naïve ☕")
    }

    @Test("rejects an unknown encoding tag rather than guessing")
    func unknownTag() {
        #expect(throws: LocalStorageError.unknownEncodingTag(7)) { try LocalStorage.decodeValue([0x07, 0x61]) }
    }

    @Test("rejects an empty value")
    func empty() {
        #expect(throws: LocalStorageError.emptyValue) { try LocalStorage.decodeValue([]) }
    }
}
