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
}
