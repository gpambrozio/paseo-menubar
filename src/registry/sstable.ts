import { uncompress } from "snappyjs";
import { crc32c, readVarint32, readVarint64, unmaskCrc, view } from "./binary.js";

/**
 * One record as LevelDB stores it: a user key, the sequence number that orders
 * it against every other write, and whether it is a deletion.
 *
 * Sequence is what lets the directory reader pick a winner without parsing the
 * MANIFEST: the same user key can appear in several files, and the highest
 * sequence is by definition the newest.
 */
export interface InternalRecord {
  userKey: Uint8Array;
  sequence: number;
  isDeletion: boolean;
  value: Uint8Array;
}

/**
 * Thrown when a block's compression byte is neither `0` (none) nor `1`
 * (snappy). Distinguished from the generic parse errors this module also
 * throws so callers can tell "the storage format moved under us" apart from
 * "this file is torn" — the two need different recovery, per the design
 * doc's failure table.
 */
export class UnsupportedCompressionError extends Error {
  readonly compression: number;

  constructor(compression: number) {
    super(`Unsupported LevelDB compression type ${compression}. The Paseo app's storage format changed.`);
    this.name = "UnsupportedCompressionError";
    this.compression = compression;
  }
}

const FOOTER_LENGTH = 48;
const MAGIC_LOW = 0x8b80fb57;
const MAGIC_HIGH = 0xdb477524;
const BLOCK_TRAILER_LENGTH = 5; // 1 compression byte + 4 checksum bytes

interface BlockHandle {
  offset: number;
  size: number;
}

function parseFooter(file: Uint8Array): BlockHandle {
  if (file.length < FOOTER_LENGTH) throw new Error("file is too short to be an SSTable");
  const footer = file.subarray(file.length - FOOTER_LENGTH);
  const dv = view(footer);
  if (dv.getUint32(40, true) !== MAGIC_LOW || dv.getUint32(44, true) !== MAGIC_HIGH) {
    throw new Error("not an SSTable: bad table magic");
  }
  // metaindex handle first, then the index handle we actually want.
  let pos = 0;
  ({ next: pos } = readVarint64(footer, pos));
  ({ next: pos } = readVarint64(footer, pos));
  const offset = readVarint64(footer, pos);
  const size = readVarint64(footer, offset.next);
  return { offset: offset.value, size: size.value };
}

/**
 * Reads one block, verifying its checksum before anything parses it.
 *
 * We never hold the database lock, so we read while Chromium writes and while
 * compactions rename files underneath us. The checksum is the only thing
 * standing between a torn read and silently wrong credentials, so a mismatch
 * is an error rather than a best-effort parse.
 */
function readBlock(file: Uint8Array, handle: BlockHandle): Uint8Array {
  const end = handle.offset + handle.size + BLOCK_TRAILER_LENGTH;
  if (end > file.length) throw new Error("block handle points past the end of the file");
  const contents = file.subarray(handle.offset, handle.offset + handle.size);
  const compression = file[handle.offset + handle.size]!;
  const storedCrc = view(file).getUint32(handle.offset + handle.size + 1, true);

  // The checksum covers the block contents plus the compression byte.
  const checked = file.subarray(handle.offset, handle.offset + handle.size + 1);
  if (crc32c(checked) !== unmaskCrc(storedCrc)) {
    throw new Error("LevelDB block failed its checksum");
  }

  if (compression === 0) return contents;
  if (compression === 1) return uncompress(contents);
  throw new UnsupportedCompressionError(compression);
}

interface BlockEntry {
  key: Uint8Array;
  value: Uint8Array;
}

/**
 * Walks a block's entries. Keys are prefix-compressed against the previous
 * key, which is why this cannot seek directly and has to read forward.
 */
function blockEntries(block: Uint8Array): BlockEntry[] {
  if (block.length < 4) throw new Error("block is too short");
  const dv = view(block);
  const restartCount = dv.getUint32(block.length - 4, true);
  const entriesEnd = block.length - 4 - restartCount * 4;
  if (entriesEnd < 0) throw new Error("block restart array overruns the block");

  const entries: BlockEntry[] = [];
  let pos = 0;
  let previousKey = new Uint8Array(0);
  while (pos < entriesEnd) {
    const shared = readVarint32(block, pos);
    const nonShared = readVarint32(block, shared.next);
    const valueLength = readVarint32(block, nonShared.next);
    pos = valueLength.next;

    if (shared.value > previousKey.length) throw new Error("block entry shares more than it can");
    const key = new Uint8Array(shared.value + nonShared.value);
    key.set(previousKey.subarray(0, shared.value), 0);
    key.set(block.subarray(pos, pos + nonShared.value), shared.value);
    pos += nonShared.value;

    const value = block.subarray(pos, pos + valueLength.value);
    pos += valueLength.value;

    previousKey = key;
    entries.push({ key, value });
  }
  return entries;
}

/**
 * Splits an internal key into its user key and 8-byte trailer of
 * `(sequence << 8) | type`, stored little-endian. Type 0 is a deletion.
 */
function splitInternalKey(key: Uint8Array): Omit<InternalRecord, "value"> {
  if (key.length < 8) throw new Error("internal key is missing its trailer");
  const dv = view(key);
  const low = dv.getUint32(key.length - 8, true);
  const high = dv.getUint32(key.length - 4, true);
  return {
    userKey: key.subarray(0, key.length - 8),
    // Sequence is 56 bits; the low byte of `low` is the record type.
    sequence: high * 0x1000000 + (low >>> 8),
    isDeletion: (low & 0xff) === 0,
  };
}

/**
 * Every record for `userKey` in one `.ldb`.
 *
 * Uses the index block to visit only the data blocks whose range can contain
 * the key, rather than decompressing the whole file. A key can legitimately
 * appear more than once with different sequence numbers, so this returns all
 * matches and leaves the choice to the caller.
 */
export function findInTable(file: Uint8Array, userKey: Uint8Array): InternalRecord[] {
  const indexBlock = readBlock(file, parseFooter(file));
  const found: InternalRecord[] = [];

  for (const indexEntry of blockEntries(indexBlock)) {
    // An index entry's key is a separator >= every key in its block, so a
    // block can hold our key only if its separator is not below it.
    const separator = splitInternalKey(indexEntry.key).userKey;
    const cmp = Buffer.compare(separator, userKey);
    if (cmp < 0) continue;

    const offset = readVarint64(indexEntry.value, 0);
    const size = readVarint64(indexEntry.value, offset.next);
    const dataBlock = readBlock(file, { offset: offset.value, size: size.value });

    for (const entry of blockEntries(dataBlock)) {
      const parsed = splitInternalKey(entry.key);
      if (Buffer.compare(parsed.userKey, userKey) !== 0) continue;
      found.push({ ...parsed, value: entry.value });
    }

    // separator >= every key in this block, so a separator strictly greater
    // than the key we want means the next block starts past it. An equal
    // separator does not: a run of records sharing one user key can straddle
    // a block boundary.
    if (cmp > 0) break;
  }
  return found;
}
