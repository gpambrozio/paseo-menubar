/**
 * Varint, checksum, and byte-view primitives for LevelDB's on-disk formats.
 *
 * Deliberately knows nothing about LevelDB: both the SSTable reader and the
 * write-ahead-log reader need these, and keeping them separate is what lets
 * each of those be tested against its own format alone.
 */

export interface VarintResult {
  value: number;
  /** Offset just past the varint, so callers can thread position through. */
  next: number;
}

/** A DataView over exactly `buf`'s bytes, honouring its offset into a shared ArrayBuffer. */
export function view(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
}

/**
 * Reads a base-128 varint.
 *
 * Throws on a truncated buffer rather than returning a partial value: every
 * caller is parsing a file another process is actively writing, and a silently
 * short read there is the difference between "retry" and "wrong credentials".
 */
export function readVarint32(buf: Uint8Array, pos: number): VarintResult {
  let result = 0;
  let shift = 0;
  let cursor = pos;
  for (;;) {
    const byte = buf[cursor++];
    if (byte === undefined) throw new Error("varint32 ran past end of buffer");
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7;
    if (shift > 28) throw new Error("varint32 is longer than 5 bytes");
  }
  return { value: result >>> 0, next: cursor };
}

/**
 * Reads a 64-bit varint as a JS number.
 *
 * Block offsets and sizes are the only 64-bit varints we read, and they are
 * bounded by file size, so `number` is exact well past any real file. Values
 * beyond 2^53 are rejected rather than silently rounded.
 */
export function readVarint64(buf: Uint8Array, pos: number): VarintResult {
  let result = 0n;
  let shift = 0n;
  let cursor = pos;
  for (;;) {
    const byte = buf[cursor++];
    if (byte === undefined) throw new Error("varint64 ran past end of buffer");
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7n;
    if (shift > 63n) throw new Error("varint64 is longer than 10 bytes");
  }
  if (result > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("varint64 exceeds the safe integer range");
  }
  return { value: Number(result), next: cursor };
}

// CRC32C (Castagnoli), reversed polynomial. LevelDB uses this, not CRC32.
const CRC32C_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0x82f63b78 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32c(buf: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc = CRC32C_TABLE[(crc ^ buf[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

const MASK_DELTA = 0xa282ead8;

/**
 * Applies LevelDB's CRC mask: stored checksums are rotated and offset so that
 * a checksum never appears verbatim in the data it covers. The readers only
 * ever unmask; this is exported so the tests that build fixtures by hand
 * share one definition with `unmaskCrc` instead of each carrying an inverse.
 */
export function maskCrc(crc: number): number {
  const rot = ((crc >>> 15) | (crc << 17)) >>> 0;
  return (rot + MASK_DELTA) >>> 0;
}

/** Reverses `maskCrc`. */
export function unmaskCrc(masked: number): number {
  const rot = (masked - MASK_DELTA) >>> 0;
  return ((rot >>> 17) | (rot << 15)) >>> 0;
}
