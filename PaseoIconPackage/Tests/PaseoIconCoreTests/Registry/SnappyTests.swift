import Foundation
import Testing
@testable import PaseoIconCore

struct SnappyTests {
    @Test("decodes an empty stream")
    func empty() throws {
        #expect(try Snappy.uncompress([0x00][...]) == [])
    }

    @Test("decodes a short literal")
    func literal() throws {
        // preamble 1, literal tag (len 1), 'a'
        #expect(try Snappy.uncompress([0x01, 0x00, 0x61][...]) == Array("a".utf8))
    }

    @Test("decodes overlapping copies with a 1-byte offset, byte by byte")
    func overlappingCopy() throws {
        // 20 × 'a': literal 'a', then copy len 11 offset 1, then copy len 8 offset 1.
        let stream: [UInt8] = [0x14, 0x00, 0x61, 0x1d, 0x01, 0x11, 0x01]
        #expect(try Snappy.uncompress(stream[...]) == Array(repeating: 0x61, count: 20))
    }

    @Test("decodes copies with 2-byte and 4-byte offsets")
    func longOffsets() throws {
        // "abcd" then copy len 4 offset 4 (2-byte form), then copy len 2 offset 8 (4-byte form).
        let stream: [UInt8] = [0x0a, 0x0c, 0x61, 0x62, 0x63, 0x64, 0x0e, 0x04, 0x00, 0x07, 0x08, 0x00, 0x00, 0x00]
        #expect(try Snappy.uncompress(stream[...]) == Array("abcdabcdab".utf8))
    }

    @Test("decodes a literal longer than 60 bytes, whose length rides in trailing bytes")
    func longLiteral() throws {
        let payload = [UInt8](repeating: 0x7a, count: 100)
        // preamble 100 (varint 0x64), tag 60<<2 = 0xf0 (one trailing length byte), length-1 = 99
        let stream: [UInt8] = [0x64, 0xf0, 0x63] + payload
        #expect(try Snappy.uncompress(stream[...]) == payload)
    }

    @Test("rejects a copy that reaches before the start of the output")
    func badOffset() {
        #expect(throws: SnappyError.badOffset) {
            try Snappy.uncompress([0x04, 0x01, 0x05][...])
        }
    }

    @Test("rejects a stream whose output length does not match its preamble")
    func lengthMismatch() {
        #expect(throws: SnappyError.lengthMismatch(expected: 5, actual: 1)) {
            try Snappy.uncompress([0x05, 0x00, 0x61][...])
        }
    }

    @Test("rejects a truncated literal")
    func truncated() {
        #expect(throws: SnappyError.truncated) {
            try Snappy.uncompress([0x03, 0x08, 0x61][...])
        }
    }
}
