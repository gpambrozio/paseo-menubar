import Foundation
import Testing
@testable import PaseoIconCore

/// Builds synthetic `.log` bytes by hand: no fixture exercises fragmentation,
/// since every fixture payload fits one 32KB block and is written as a single
/// FULL record. The FIRST/MIDDLE/LAST reassembly path is driven directly here.
enum LogBuilder {
    static let typeFull: UInt8 = 1
    static let typeFirst: UInt8 = 2
    static let typeMiddle: UInt8 = 3
    static let typeLast: UInt8 = 4
    static let unknownType: UInt8 = 9

    static func varint(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var n = n
        while n > 0x7f {
            bytes.append(UInt8(n & 0x7f) | 0x80)
            n >>= 7
        }
        bytes.append(UInt8(n))
        return bytes
    }

    /// One logical record inside a write batch: type + key + value.
    static func writeRecord(key: [UInt8], value: [UInt8]) -> [UInt8] {
        [1] + varint(key.count) + key + varint(value.count) + value
    }

    /// A write batch: 8-byte base sequence, 4-byte count, then the records.
    /// `baseSequence` is a parameter because the header's high words come
    /// straight off disk and nothing signs this file, so they are reachable
    /// input rather than an internal detail.
    static func batch(_ records: [[UInt8]], baseSequence: UInt64 = 1, declaredCount: UInt32? = nil) -> [UInt8] {
        var header: [UInt8] = (0..<8).map { UInt8((baseSequence >> (8 * $0)) & 0xff) }
        let count = declaredCount ?? UInt32(records.count)
        header += [UInt8(count & 0xff), UInt8((count >> 8) & 0xff), UInt8((count >> 16) & 0xff), UInt8(count >> 24)]
        return header + records.flatMap { $0 }
    }

    /// One physical log record: 4-byte masked CRC, 2-byte LE length, 1-byte
    /// type, then the payload. `corruptByte` flips a bit in the stored payload
    /// after the checksum was computed, simulating real corruption.
    static func physical(_ type: UInt8, _ payload: [UInt8], corruptByte: Int? = nil) -> [UInt8] {
        let crc = Binary.maskCrc(Binary.crc32c([type] + payload))
        var record: [UInt8] = [UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff), UInt8((crc >> 16) & 0xff), UInt8(crc >> 24)]
        record += [UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff), type]
        record += payload
        if let corruptByte { record[7 + corruptByte] ^= 0xff }
        return record
    }

    /// A header claiming `length` bytes with no payload behind it.
    static func overlongHeader(_ type: UInt8, length: Int) -> [UInt8] {
        [0, 0, 0, 0, UInt8(length & 0xff), UInt8((length >> 8) & 0xff), type]
    }

    static func splitThree(_ bytes: [UInt8]) -> ([UInt8], [UInt8], [UInt8]) {
        let third = (bytes.count + 2) / 3
        return (Array(bytes[0..<third]), Array(bytes[third..<(third * 2)]), Array(bytes[(third * 2)...]))
    }
}

struct WALTests {
    private let key = RegistryFixtures.registryKey

    @Test("finds a record written but never compacted")
    func logOnly() throws {
        let scan = try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: key)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(scan.records.first?.value)).contains("log-only"))
    }

    @Test("reports a deletion as a deletion, not as an empty value")
    func deletion() throws {
        let scan = try WAL.find(in: try RegistryFixtures.logBytes("deleted"), userKey: key)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == true)
    }

    @Test("returns nothing for an unrelated key")
    func unrelated() throws {
        #expect(try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: Array("_nope".utf8)).records.isEmpty)
    }

    @Test("skips a record whose checksum does not match, and counts it")
    func corruptRecord() throws {
        var bytes = try RegistryFixtures.logBytes("log-only")
        // Corrupt the first record's payload, leaving its header intact.
        bytes[8] ^= 0xff
        let scan = try WAL.find(in: bytes, userKey: key)
        #expect(scan.records.isEmpty)
        #expect(scan.droppedFragments == 1)
    }

    @Test("counts nothing when the log is intact")
    func intact() throws {
        #expect(try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: key).droppedFragments == 0)
    }

    private let myKey = Array("mykey".utf8)
    private let myValue = Array("myvalue-that-is-reasonably-long-to-force-fragmentation".utf8)

    private func fragments() -> ([UInt8], [UInt8], [UInt8]) {
        LogBuilder.splitThree(LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: myValue)]))
    }

    @Test("reassembles a batch split across FIRST/MIDDLE/LAST")
    func reassembles() throws {
        let (f1, f2, f3) = fragments()
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeMiddle, f2) + LogBuilder.physical(LogBuilder.typeLast, f3)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == false)
        #expect(scan.records.first?.value == myValue)
    }

    @Test("discards the whole batch when the MIDDLE fragment is corrupt")
    func corruptMiddle() throws {
        let (f1, f2, f3) = fragments()
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeMiddle, f2, corruptByte: 0) + LogBuilder.physical(LogBuilder.typeLast, f3)
        #expect(try WAL.find(in: log, userKey: myKey).records.isEmpty)
    }

    @Test("does not let a FIRST with no matching LAST leak into the next batch")
    func abandonedFirst() throws {
        let (f1, _, _) = fragments()
        let otherKey = Array("otherkey".utf8)
        let otherValue = Array("otherval".utf8)
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeFull, LogBuilder.batch([LogBuilder.writeRecord(key: otherKey, value: otherValue)]))
        #expect(try WAL.find(in: log, userKey: myKey).records.isEmpty)
        let scan = try WAL.find(in: log, userKey: otherKey)
        #expect(scan.records.first?.value == otherValue)
        // An abandoned FIRST is the normal shape of a log being appended to.
        #expect(scan.droppedFragments == 0)
    }

    @Test("discards the batch when a fragment in an earlier block claims more bytes than the block holds")
    func overlongInsideBlock() throws {
        let (f1, _, _) = fragments()
        let decoyBatch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: Array("decoy-carried-by-the-last-fragment".utf8))])
        let block0 = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.overlongHeader(LogBuilder.typeMiddle, length: 0x7fff)
        let log = block0 + [UInt8](repeating: 0, count: 32768 - block0.count) + LogBuilder.physical(LogBuilder.typeLast, decoyBatch)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.isEmpty)
        #expect(scan.droppedFragments == 1)
    }

    @Test("does not count a record torn at the end of the file as damage")
    func tornTail() throws {
        let batch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: Array("v".utf8))])
        let log = LogBuilder.physical(LogBuilder.typeFull, batch) + LogBuilder.overlongHeader(LogBuilder.typeFull, length: 0x7fff)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.count == 1)
        #expect(scan.droppedFragments == 0)
    }

    @Test("discards the batch when an unrecognized fragment type appears between FIRST and LAST")
    func unknownType() throws {
        let (f1, f2, _) = fragments()
        let decoyValue = Array("decoy-carried-by-the-last-fragment".utf8)
        let decoyBatch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: decoyValue)])
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.unknownType, f2) + LogBuilder.physical(LogBuilder.typeLast, decoyBatch)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.droppedFragments == 1)
        #expect(!scan.records.contains { $0.value == decoyValue })
        #expect(scan.records.isEmpty)
    }
    @Test("refuses a batch whose base sequence would overflow, rather than trapping")
    func sequenceOverflow() throws {
        // The two header words are raw little-endian bytes, so a batch can
        // declare UInt64.max. `baseSequence + UInt64(index)` on the second
        // record then overflows, and a Swift overflow traps uncatchably: the
        // menu bar item disappears with nothing to click. The CRC does not
        // protect against this — it is computed over whatever bytes are there,
        // so anything able to write under the Paseo app's storage produces it
        // deterministically. The evidence this test works is a crashed test
        // process, not a failed expectation.
        let batch = LogBuilder.batch(
            [LogBuilder.writeRecord(key: myKey, value: Array("a".utf8)),
             LogBuilder.writeRecord(key: myKey, value: Array("b".utf8))],
            baseSequence: UInt64.max
        )
        let scan = try WAL.find(in: LogBuilder.physical(LogBuilder.typeFull, batch), userKey: myKey)
        #expect(scan.records.isEmpty)
        // Refused, not silently skipped: the tray has to be able to say the log
        // lost something.
        #expect(scan.droppedFragments == 1)
    }

    @Test("a batch truncated mid-record keeps the batches already read out of the file")
    func truncatedBatchKeepsEarlierOnes() throws {
        // A length that runs off the end used to throw, and the throw reached
        // LevelDBReader, which counts the whole file as damage — discarding
        // every good batch before it, possibly the newest registry write.
        let good = LogBuilder.physical(
            LogBuilder.typeFull,
            LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: Array("kept".utf8))])
        )
        // A batch whose only record stops immediately after its type byte, so
        // the key's varint has nothing to read.
        let truncated = LogBuilder.physical(LogBuilder.typeFull, LogBuilder.batch([[1]], baseSequence: 9))
        let scan = try WAL.find(in: good + truncated, userKey: myKey)
        #expect(scan.records.map { String(decoding: $0.value, as: UTF8.self) } == ["kept"])
        #expect(scan.droppedFragments == 1)
    }

    @Test("a batch that delivers fewer records than its header promised says so")
    func shortBatchIsCounted() throws {
        // The batch ends cleanly on a record boundary, so no length runs off the
        // end and no varint fails — the loop simply runs out of bytes with
        // records still owed. Every other early exit counts its loss; this one
        // used to report a clean read, so the tray showed a host list with no
        // hint that a record was missing.
        let batch = LogBuilder.batch(
            [LogBuilder.writeRecord(key: myKey, value: Array("only-one".utf8))],
            declaredCount: 2
        )
        let scan = try WAL.find(in: LogBuilder.physical(LogBuilder.typeFull, batch), userKey: myKey)
        #expect(scan.records.map { String(decoding: $0.value, as: UTF8.self) } == ["only-one"])
        #expect(scan.droppedFragments == 1)
    }

}
