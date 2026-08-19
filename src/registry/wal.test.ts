import { describe, expect, it } from "vitest";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { crc32c } from "./binary.js";
import { findInLog } from "./wal.js";

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

// --- Synthetic log builder ---------------------------------------------
//
// No fixture exercises fragmentation: every real payload the fixtures cover
// fits inside one 32KB block, so it is always written as a single TYPE_FULL
// record. The FIRST/MIDDLE/LAST reassembly path — the riskiest code in
// wal.ts — is otherwise untested. These helpers build a synthetic `.log`
// buffer by hand so the tests below can drive that path directly.
//
// Note the mild circularity: `maskCrc` here is the inverse of `unmaskCrc`
// from binary.js, and both the test and the implementation route through
// the same `crc32c`. That is acceptable because what these tests pin down
// is wal.ts's *framing and reassembly* logic — how FIRST/MIDDLE/LAST
// fragments combine, and what happens when one of them is wrong — not
// whether crc32c itself is correct. CRC32C correctness is pinned against
// the standard check vector in binary.test.ts (Task 1).

const TYPE_FULL = 1;
const TYPE_FIRST = 2;
const TYPE_MIDDLE = 3;
const TYPE_LAST = 4;
const UNKNOWN_TYPE = 9;

const RECORD_VALUE = 1;

const MASK_DELTA = 0xa282ead8;

function maskCrc(crc: number): number {
  const rotated = (((crc << 17) | (crc >>> 15)) >>> 0) >>> 0;
  return (rotated + MASK_DELTA) >>> 0;
}

function varint(n: number): Buffer {
  const bytes: number[] = [];
  while (n > 0x7f) {
    bytes.push((n & 0x7f) | 0x80);
    n >>>= 7;
  }
  bytes.push(n);
  return Buffer.from(bytes);
}

/** One logical record inside a write batch: type + key (+ value). */
function makeWriteRecord(key: Buffer, value: Buffer): Buffer {
  return Buffer.concat([Buffer.from([RECORD_VALUE]), varint(key.length), key, varint(value.length), value]);
}

/** A write batch: 8-byte base sequence, 4-byte count, then the records. */
function makeBatch(records: Buffer[]): Buffer {
  const header = Buffer.alloc(12);
  header.writeUInt32LE(1, 0); // base sequence low
  header.writeUInt32LE(0, 4); // base sequence high
  header.writeUInt32LE(records.length, 8);
  return Buffer.concat([header, ...records]);
}

/**
 * One physical log record: 4-byte masked CRC, 2-byte LE length, 1-byte type,
 * then the payload. The CRC is always computed from the given (intact)
 * payload; `corruptByte`, if given, flips a bit in the *stored* payload
 * afterward, so the checksum in the header stops matching what is on disk —
 * simulating real corruption rather than hashing already-bad data.
 */
function physicalRecord(type: number, payload: Buffer, corruptByte?: number): Buffer {
  const checked = Buffer.concat([Buffer.from([type]), payload]);
  const crc = maskCrc(crc32c(checked));
  const header = Buffer.alloc(7);
  header.writeUInt32LE(crc, 0);
  header.writeUInt16LE(payload.length, 4);
  header.writeUInt8(type, 6);
  const record = Buffer.concat([header, payload]);
  if (corruptByte !== undefined) record[7 + corruptByte] = record[7 + corruptByte]! ^ 0xff;
  return record;
}

/** Splits a batch's bytes into three roughly-even fragments. */
function splitThree(batch: Buffer): [Buffer, Buffer, Buffer] {
  const third = Math.ceil(batch.length / 3);
  return [batch.subarray(0, third), batch.subarray(third, third * 2), batch.subarray(third * 2)];
}

const KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("@paseo:daemon-registry", "latin1"),
]);

async function logBytes(fixture: string): Promise<Buffer> {
  const dir = path.join(FIXTURES, fixture);
  const names = (await readdir(dir)).filter((name) => name.endsWith(".log"));
  if (names.length === 0) throw new Error(`no .log in ${fixture}`);
  return readFile(path.join(dir, names[0]!));
}

describe("findInLog", () => {
  it("finds a record written but never compacted", async () => {
    const records = findInLog(await logBytes("log-only"), KEY);
    expect(records).toHaveLength(1);
    expect(records[0]!.isDeletion).toBe(false);
    expect(Buffer.from(records[0]!.value).subarray(1).toString("latin1")).toContain("log-only");
  });

  it("reports a deletion as a deletion, not as an empty value", async () => {
    const records = findInLog(await logBytes("deleted"), KEY);
    expect(records).toHaveLength(1);
    expect(records[0]!.isDeletion).toBe(true);
  });

  it("returns nothing for an unrelated key", async () => {
    expect(findInLog(await logBytes("log-only"), Buffer.from("_nope", "latin1"))).toEqual([]);
  });

  it("skips a record whose checksum does not match rather than trusting it", async () => {
    const bytes = Buffer.from(await logBytes("log-only"));
    // Corrupt the first record's payload, leaving its header intact.
    bytes[8] = bytes[8]! ^ 0xff;
    expect(findInLog(bytes, KEY)).toEqual([]);
  });
});

describe("findInLog: multi-fragment reassembly", () => {
  const key = Buffer.from("mykey", "latin1");
  // Long enough that splitting it into three physical records is meaningful.
  const value = Buffer.from("myvalue-that-is-reasonably-long-to-force-fragmentation", "latin1");
  const batch = makeBatch([makeWriteRecord(key, value)]);
  const [frag1, frag2, frag3] = splitThree(batch);

  it("reassembles a batch split across FIRST/MIDDLE/LAST into the correct record", () => {
    const log = Buffer.concat([
      physicalRecord(TYPE_FIRST, frag1),
      physicalRecord(TYPE_MIDDLE, frag2),
      physicalRecord(TYPE_LAST, frag3),
    ]);
    const records = findInLog(log, key);
    expect(records).toHaveLength(1);
    expect(records[0]!.isDeletion).toBe(false);
    expect(Buffer.from(records[0]!.value).toString("latin1")).toBe(value.toString("latin1"));
  });

  it("discards the whole batch, not a truncated record, when the MIDDLE fragment is corrupt", () => {
    const log = Buffer.concat([
      physicalRecord(TYPE_FIRST, frag1),
      physicalRecord(TYPE_MIDDLE, frag2, 0),
      physicalRecord(TYPE_LAST, frag3),
    ]);
    expect(findInLog(log, key)).toEqual([]);
  });

  it("does not let a FIRST with no matching LAST leak into the next batch", () => {
    const otherKey = Buffer.from("otherkey", "latin1");
    const otherValue = Buffer.from("otherval", "latin1");
    const otherBatch = makeBatch([makeWriteRecord(otherKey, otherValue)]);

    const log = Buffer.concat([
      physicalRecord(TYPE_FIRST, frag1),
      // No MIDDLE/LAST follows: the FIRST batch is simply abandoned, as
      // happens at the tail of a log that is still being appended to.
      physicalRecord(TYPE_FULL, otherBatch),
    ]);

    expect(findInLog(log, key)).toEqual([]);
    const found = findInLog(log, otherKey);
    expect(found).toHaveLength(1);
    expect(Buffer.from(found[0]!.value).toString("latin1")).toBe(otherValue.toString("latin1"));
  });

  it("discards the batch when an unrecognized fragment type appears between FIRST and LAST", () => {
    // The LAST fragment here is deliberately a *well-formed* one-record batch
    // for the same key, carrying a value the reader must never return.
    //
    // With `frag3` in this slot the test passes for the wrong reason: that
    // fragment alone decodes to a garbage batch whose key matches nothing, so
    // the result is empty even if the unrecognized-type branch cleared
    // `pending` instead of tainting it — the exact bug wal.ts's comment says
    // it prevents. A decoy that would decode cleanly is what makes this test
    // discriminate.
    const decoyValue = Buffer.from("decoy-carried-by-the-last-fragment", "latin1");
    const decoyBatch = makeBatch([makeWriteRecord(key, decoyValue)]);
    const log = Buffer.concat([
      physicalRecord(TYPE_FIRST, frag1),
      physicalRecord(UNKNOWN_TYPE, frag2),
      physicalRecord(TYPE_LAST, decoyBatch),
    ]);

    const records = findInLog(log, key);
    expect(records.map((record) => Buffer.from(record.value).toString("latin1"))).not.toContain(
      decoyValue.toString("latin1"),
    );
    expect(records).toEqual([]);
  });
});
