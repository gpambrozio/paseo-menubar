import Foundation
import Testing
@testable import PaseoIconCore

struct BinaryTests {
    @Test("reads a single-byte varint32 and reports the next offset")
    func singleByte() throws {
        let result = try Binary.readVarint32([0x05], at: 0)
        #expect(result.value == 5)
        #expect(result.next == 1)
    }

    @Test("reads a multi-byte varint32")
    func multiByte() throws {
        // 300 = 0b100101100 -> 0xac 0x02
        let result = try Binary.readVarint32([0xac, 0x02], at: 0)
        #expect(result.value == 300)
        #expect(result.next == 2)
    }

    @Test("reads a varint32 from a non-zero offset")
    func nonZeroOffset() throws {
        let result = try Binary.readVarint32([0xff, 0xac, 0x02], at: 1)
        #expect(result.value == 300)
        #expect(result.next == 3)
    }

    @Test("throws rather than returning garbage when the buffer ends mid-varint")
    func truncated() {
        #expect(throws: BinaryError.varintPastEnd("varint32 ran past end of buffer")) {
            try Binary.readVarint32([0x80], at: 0)
        }
    }

    @Test("reads a varint64 above the 32-bit range")
    func varint64() throws {
        // 2^35 = 34359738368
        let result = try Binary.readVarint64([0x80, 0x80, 0x80, 0x80, 0x80, 0x01], at: 0)
        #expect(result.value == 34_359_738_368)
        #expect(result.next == 6)
    }

    @Test("crc32c matches the standard check vector")
    func crcCheckVector() {
        // The CRC32C check value for "123456789" is 0xE3069283.
        #expect(Binary.crc32c(Array("123456789".utf8)) == 0xe306_9283)
    }

    @Test("crc round-trips through LevelDB's mask")
    func maskRoundTrip() {
        let crc = Binary.crc32c(Array("paseo".utf8))
        #expect(Binary.unmaskCrc(Binary.maskCrc(crc)) == crc)
    }

    @Test("masks the way LevelDB does, not merely in a way unmaskCrc undoes")
    func maskFormula() {
        // LevelDB: ((crc >> 15) | (crc << 17)) + 0xa282ead8, pinned as an
        // independent expression so a matching mistake in both directions
        // cannot pass the round-trip above.
        let crc: UInt32 = 0x1234_5678
        #expect(Binary.maskCrc(crc) == ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8)
    }

    @Test("compares bytes unsigned, shorter prefix first")
    func compare() {
        #expect(Binary.compare([1, 2][...], [1, 2][...]) == 0)
        #expect(Binary.compare([1][...], [1, 2][...]) < 0)
        #expect(Binary.compare([0xff][...], [0x01][...]) > 0)
        #expect(Binary.compare([][...], [0][...]) < 0)
    }
}
