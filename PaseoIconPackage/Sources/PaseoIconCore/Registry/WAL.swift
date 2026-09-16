import Foundation

/// What one `.log` yielded, and how much of it had to be thrown away.
public struct LogScan: Equatable, Sendable {
    public let records: [InternalRecord]
    /// Fragments discarded because their checksum failed, their type was not
    /// one of FULL/FIRST/MIDDLE/LAST, or their declared length ran past the
    /// block that holds them. Counted, rather than merely dropped, because a
    /// dropped fragment can be the newest write of the key we came for. A
    /// fragment abandoned at the end of the file is not counted: a log being
    /// appended to routinely ends mid-batch.
    public let droppedFragments: Int
}

/// One LevelDB `.log`: record framing and batches.
public enum WAL {
    private static let blockSize = 32768
    private static let headerSize = 7 // checksum(4) + length(2) + type(1)
    private static let typeFull: UInt8 = 1
    private static let typeFirst: UInt8 = 2
    private static let typeMiddle: UInt8 = 3
    private static let typeLast: UInt8 = 4
    private static let recordDeletion: UInt8 = 0
    private static let recordValue: UInt8 = 1

    /// Every record for `userKey` in one `.log`, plus what the log lost.
    public static func find(in file: [UInt8], userKey: [UInt8]) throws -> LogScan {
        var found: [InternalRecord] = []
        let scan = readBatches(file)
        for batch in scan.batches {
            for record in try batchRecords(batch) where Binary.compare(record.userKey[...], userKey[...]) == 0 {
                found.append(record)
            }
        }
        return LogScan(records: found, droppedFragments: scan.droppedFragments)
    }

    /// Reassembles the physical records of a write-ahead log into batch
    /// payloads. A log is a sequence of 32KB blocks, and one batch can be split
    /// across block boundaries into FIRST/MIDDLE/LAST fragments. A fragment
    /// whose checksum fails is dropped along with the batch it belongs to, and
    /// counted.
    private static func readBatches(_ file: [UInt8]) -> (batches: [[UInt8]], droppedFragments: Int) {
        var batches: [[UInt8]] = []
        var droppedFragments = 0
        var pending: [UInt8] = []
        // Once any fragment of the batch under assembly is bad, the whole
        // batch is discarded at its LAST rather than spliced with a hole.
        var pendingCorrupt = false

        var blockStart = 0
        while blockStart < file.count {
            let blockEnd = min(blockStart + blockSize, file.count)
            var pos = blockStart

            while pos + headerSize <= blockEnd {
                let length = Int(Binary.readUInt16LE(file, at: pos + 4))
                let type = file[pos + 6]
                // A run of zeroes is the block's trailing padding, not a record.
                if type == 0 && length == 0 { break }
                let payloadEnd = pos + headerSize + length
                if payloadEnd > blockEnd {
                    // At the end of the file this is the torn tail of a log
                    // still being appended to. Inside an earlier block it is a
                    // record claiming more bytes than its block holds, and the
                    // batch in progress can no longer be trusted.
                    if blockEnd != file.count {
                        droppedFragments += 1
                        pendingCorrupt = true
                    }
                    break
                }

                let storedCrc = Binary.readUInt32LE(file, at: pos)
                // The checksum covers the type byte and the payload, not the header.
                let checked = file[(pos + 6)..<payloadEnd]
                let payload = file[(pos + headerSize)..<payloadEnd]
                let intact = Binary.crc32c(checked) == Binary.unmaskCrc(storedCrc)
                let known = type == typeFull || type == typeFirst || type == typeMiddle || type == typeLast
                if !intact || !known { droppedFragments += 1 }
                pos = payloadEnd

                if !known {
                    // Taint the batch in progress rather than clearing it: a
                    // later LAST must see the taint and discard the whole batch.
                    pendingCorrupt = true
                    continue
                }

                if type == typeFull || type == typeFirst {
                    pending = []
                    pendingCorrupt = false
                }
                pending.append(contentsOf: payload)
                pendingCorrupt = pendingCorrupt || !intact
                if type == typeFull || type == typeLast {
                    if !pendingCorrupt { batches.append(pending) }
                    pending = []
                    pendingCorrupt = false
                }
            }
            blockStart += blockSize
        }
        return (batches, droppedFragments)
    }

    /// Decodes one write batch: an 8-byte base sequence, a 4-byte count, then
    /// that many records. Keys here are user keys with no trailer; a record's
    /// sequence is the batch's base plus its index.
    private static func batchRecords(_ batch: [UInt8]) throws -> [InternalRecord] {
        guard batch.count >= 12 else { return [] }
        let baseLow = UInt64(Binary.readUInt32LE(batch, at: 0))
        let baseHigh = UInt64(Binary.readUInt32LE(batch, at: 4))
        let baseSequence = (baseHigh << 32) | baseLow
        let count = Int(Binary.readUInt32LE(batch, at: 8))

        var records: [InternalRecord] = []
        var pos = 12
        var index = 0
        while index < count, pos < batch.count {
            let type = batch[pos]
            pos += 1
            let keyLength = try Binary.readVarint32(batch, at: pos)
            pos = keyLength.next
            let keyEnd = min(pos + Int(keyLength.value), batch.count)
            let userKey = Array(batch[pos..<keyEnd])
            pos = keyEnd

            var value: [UInt8] = []
            if type == recordValue {
                let valueLength = try Binary.readVarint32(batch, at: pos)
                pos = valueLength.next
                let valueEnd = min(pos + Int(valueLength.value), batch.count)
                value = Array(batch[pos..<valueEnd])
                pos = valueEnd
            } else if type != recordDeletion {
                // An unknown record type means we can no longer trust our
                // position in this batch, so stop rather than misread the rest.
                break
            }

            records.append(InternalRecord(
                userKey: userKey,
                sequence: baseSequence + UInt64(index),
                isDeletion: type == recordDeletion,
                value: value
            ))
            index += 1
        }
        return records
    }
}
