import { crc32c, readVarint32, unmaskCrc } from "./binary.js";
import type { InternalRecord } from "./sstable.js";

const BLOCK_SIZE = 32768;
const HEADER_SIZE = 7; // checksum(4) + length(2) + type(1)

const TYPE_FULL = 1;
const TYPE_FIRST = 2;
const TYPE_MIDDLE = 3;
const TYPE_LAST = 4;

const RECORD_DELETION = 0;
const RECORD_VALUE = 1;

function view(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
}

/** What one `.log` yielded, and how much of it had to be thrown away. */
export interface LogScan {
  records: InternalRecord[];
  /**
   * Fragments discarded because their checksum failed or their type was not
   * one of FULL/FIRST/MIDDLE/LAST.
   *
   * Counted, rather than merely dropped, because a dropped fragment can be
   * the newest write of the key we came for: the caller would otherwise
   * return an older sibling file's value as authoritative with no signal that
   * anything was missed. A fragment abandoned at the end of the file is *not*
   * counted — a log being appended to routinely ends mid-batch, and that is
   * the normal condition, not damage.
   */
  droppedFragments: number;
}

interface BatchScan {
  batches: Uint8Array[];
  droppedFragments: number;
}

/**
 * Reassembles the physical records of a write-ahead log into batch payloads.
 *
 * A log is a sequence of 32KB blocks, and one batch can be split across block
 * boundaries into FIRST/MIDDLE/LAST fragments, so this cannot simply read
 * batches back-to-back.
 *
 * A fragment whose checksum fails is dropped along with the batch it belongs
 * to, and counted. Reading while Chromium writes routinely tears the tail, so
 * this is not worth failing the whole read over — but it is worth reporting,
 * because the torn bytes may have been the newest value.
 */
function readBatches(file: Uint8Array): BatchScan {
  const dv = view(file);
  const batches: Uint8Array[] = [];
  let droppedFragments = 0;
  let pending: Uint8Array[] = [];
  let pendingCorrupt = false;

  for (let blockStart = 0; blockStart < file.length; blockStart += BLOCK_SIZE) {
    const blockEnd = Math.min(blockStart + BLOCK_SIZE, file.length);
    let pos = blockStart;

    while (pos + HEADER_SIZE <= blockEnd) {
      const length = dv.getUint16(pos + 4, true);
      const type = file[pos + 6]!;
      // A run of zeroes is the block's trailing padding, not a record.
      if (type === 0 && length === 0) break;
      const payloadEnd = pos + HEADER_SIZE + length;
      if (payloadEnd > blockEnd) break; // truncated tail

      const storedCrc = dv.getUint32(pos, true);
      // The checksum covers the type byte and the payload, not the header.
      const checked = file.subarray(pos + 6, payloadEnd);
      const payload = file.subarray(pos + HEADER_SIZE, payloadEnd);
      const intact = crc32c(checked) === unmaskCrc(storedCrc);
      if (!intact) droppedFragments += 1;

      if (type === TYPE_FULL) {
        if (intact) batches.push(payload);
        pending = [];
        pendingCorrupt = false;
      } else if (type === TYPE_FIRST) {
        pending = [payload];
        pendingCorrupt = !intact;
      } else if (type === TYPE_MIDDLE) {
        pending.push(payload);
        pendingCorrupt ||= !intact;
      } else if (type === TYPE_LAST) {
        pending.push(payload);
        pendingCorrupt ||= !intact;
        if (!pendingCorrupt && pending.length > 0) batches.push(concat(pending));
        pending = [];
        pendingCorrupt = false;
      } else {
        // An unrecognized type is itself corruption. Mark any in-progress
        // FIRST/MIDDLE reassembly as tainted rather than clearing `pending`
        // outright: a later LAST still needs to see pendingCorrupt as true
        // so it discards the whole batch, instead of finding an empty
        // `pending` and wrongly treating its own fragment as a complete
        // one-fragment batch.
        pendingCorrupt = true;
        if (intact) droppedFragments += 1;
      }

      pos = payloadEnd;
    }
  }
  return { batches, droppedFragments };
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/**
 * Decodes one write batch: an 8-byte base sequence, a 4-byte count, then that
 * many records. Unlike an SSTable, keys here are user keys with no trailer —
 * a record's sequence is the batch's base plus its index.
 */
function batchRecords(batch: Uint8Array): InternalRecord[] {
  if (batch.length < 12) return [];
  const dv = view(batch);
  const baseLow = dv.getUint32(0, true);
  const baseHigh = dv.getUint32(4, true);
  const baseSequence = baseHigh * 0x100000000 + baseLow;
  const count = dv.getUint32(8, true);

  const records: InternalRecord[] = [];
  let pos = 12;
  for (let index = 0; index < count && pos < batch.length; index++) {
    const type = batch[pos]!;
    pos += 1;
    const keyLength = readVarint32(batch, pos);
    pos = keyLength.next;
    const userKey = batch.subarray(pos, pos + keyLength.value);
    pos += keyLength.value;

    let value: Uint8Array = new Uint8Array(0);
    if (type === RECORD_VALUE) {
      const valueLength = readVarint32(batch, pos);
      pos = valueLength.next;
      value = batch.subarray(pos, pos + valueLength.value);
      pos += valueLength.value;
    } else if (type !== RECORD_DELETION) {
      // An unknown record type means we can no longer trust our position in
      // this batch, so stop rather than misread the rest of it.
      break;
    }

    records.push({
      userKey,
      sequence: baseSequence + index,
      isDeletion: type === RECORD_DELETION,
      value,
    });
  }
  return records;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** Every record for `userKey` in one `.log`, plus what the log lost. */
export function findInLog(file: Uint8Array, userKey: Uint8Array): LogScan {
  const found: InternalRecord[] = [];
  const { batches, droppedFragments } = readBatches(file);
  for (const batch of batches) {
    for (const record of batchRecords(batch)) {
      if (sameBytes(record.userKey, userKey)) found.push(record);
    }
  }
  return { records: found, droppedFragments };
}
