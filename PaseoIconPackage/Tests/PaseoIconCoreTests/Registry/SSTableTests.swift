import Foundation
import Testing
@testable import PaseoIconCore

struct SSTableTests {
    private let key = RegistryFixtures.registryKey

    @Test("finds the record in a compacted, snappy-compressed table")
    func compacted() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("compacted"), userKey: key)
        #expect(records.count == 1)
        #expect(records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("compacted"))
    }

    @Test("returns nothing for a key the table does not hold")
    func absent() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("compacted"), userKey: Array("_nope".utf8))
        #expect(records.isEmpty)
    }

    @Test("rejects a table whose block checksum does not match")
    func corruptChecksum() throws {
        var bytes = try RegistryFixtures.tableBytes("compacted")
        // Flip a bit early in the file, inside the first data block's payload.
        bytes[64] ^= 0xff
        #expect(throws: SSTableError.checksumMismatch) {
            try SSTable.find(in: bytes, userKey: key)
        }
    }

    @Test("finds the registry key even though it is not in the first data block")
    func multiBlock() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: key)
        #expect(records.count == 1)
        #expect(records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("multi-block"))
    }

    @Test("returns nothing for a key a multi-block table does not hold")
    func multiBlockAbsent() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: Array("_nope".utf8))
        #expect(records.isEmpty)
    }

    @Test("finds a key from a later data block, exercising the index seek's skip branch")
    func laterBlock() throws {
        // The last "z-key-*" filler entry sorts well after the registry key, so
        // a correct seek has to skip past several data blocks to reach it.
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: RegistryFixtures.fillerKey("z", 199))
        #expect(records.count == 1)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("multi-block filler value 199"))
    }

    @Test("finds every version of a key whose run of internal keys straddles a block boundary")
    func straddle() throws {
        // All 10 puts survive compaction; a scan that stops at an index
        // separator equal to the target would drop the second block's versions.
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: RegistryFixtures.straddleKey)
        #expect(records.count == 10)
        for record in records {
            #expect(RegistryFixtures.latin1(record.value).contains("straddle version"))
        }
    }

    @Test("names an unsupported compression type rather than guessing")
    func unsupportedCompression() throws {
        var bytes = try RegistryFixtures.tableBytes("compacted")
        // Rewrite the index block's compression byte to 99 and re-checksum it,
        // so the block parses cleanly enough to reach the compression switch.
        let footer = Array(bytes[(bytes.count - 48)...])
        var pos = try Binary.readVarint64(footer, at: 0).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let indexOffset = try Binary.readVarint64(footer, at: pos)
        let indexSize = try Binary.readVarint64(footer, at: indexOffset.next)
        let compressionByte = Int(indexOffset.value + indexSize.value)
        bytes[compressionByte] = 99
        let masked = Binary.maskCrc(Binary.crc32c(bytes[Int(indexOffset.value)...compressionByte]))
        for i in 0..<4 { bytes[compressionByte + 1 + i] = UInt8((masked >> (8 * UInt32(i))) & 0xff) }
        #expect(throws: SSTableError.unsupportedCompression(99)) {
            try SSTable.find(in: bytes, userKey: key)
        }
    }

    @Test("refuses a block handle too large for the platform's Int rather than trapping")
    func oversizedBlockHandle() throws {
        // The footer has no checksum, so a file whose magic survives while its
        // handle bytes are corrupted reaches the conversion. A ten-byte varint
        // encoding 2^63 is above Int.max, and `Int(_:)` on it would trap the
        // process rather than throw.
        var bytes = try RegistryFixtures.tableBytes("compacted")
        var huge: [UInt8] = []
        var value: UInt64 = 1 << 63
        while value > 0x7f {
            huge.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        huge.append(UInt8(value))

        // Rewrite the footer: two zero varints for the metaindex handle, then
        // the oversized index handle, then the magic, padded to 48 bytes.
        var footer: [UInt8] = [0x00, 0x00] + huge + [0x01]
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
        #expect(footer.count == 48)
        bytes.replaceSubrange((bytes.count - 48)..., with: footer)

        #expect(throws: SSTableError.blockPastEnd) {
            try SSTable.find(in: bytes, userKey: RegistryFixtures.registryKey)
        }
    }
}
