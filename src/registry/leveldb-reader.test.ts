import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, readFile, readdir, writeFile, cp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { readLevelDbValue } from "./leveldb-reader.js";
import { crc32c, maskCrc, readVarint64 } from "./binary.js";
import { localStorageKey } from "./local-storage.js";

/**
 * A per-path queue of one-shot `readFile` behaviours: the seam a test uses
 * to make one specific file vanish (or reappear) between the two scans
 * `readLevelDbValue` can run, without touching that function's public
 * signature. Each path's queue is consumed front-to-back and then left on
 * its last entry, so "throw once, then succeed" and "always throw" are both
 * expressible. Every path with no queue registered passes straight through
 * to the real filesystem, so the fixture-building helpers below this block
 * are unaffected.
 */
const readFileQueues = vi.hoisted(() => new Map<string, Array<() => Promise<Buffer>>>());

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    // `any` here is test-only mock glue matching `readFile`'s overloaded signature.
    readFile: vi.fn((filePath: any, ...rest: any[]) => {
      const queue = readFileQueues.get(String(filePath));
      if (queue && queue.length > 0) {
        const behavior = queue.length > 1 ? queue.shift()! : queue[0]!;
        return behavior();
      }
      return actual.readFile(filePath, ...rest);
    }),
  };
});

afterEach(() => {
  readFileQueues.clear();
});

function fsError(code: string, filePath: string): NodeJS.ErrnoException {
  const error = new Error(`${code}: open '${filePath}'`) as NodeJS.ErrnoException;
  error.code = code;
  return error;
}

function enoentError(filePath: string): NodeJS.ErrnoException {
  return fsError("ENOENT", filePath);
}

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

const KEY = localStorageKey("paseo://app", "@paseo:daemon-registry");

function text(value: Uint8Array | null): string {
  if (!value) throw new Error("expected a value");
  return Buffer.from(value).subarray(1).toString("latin1");
}

/** The value alone, asserting the read reported no damage along the way. */
async function cleanValue(dir: string, key: Uint8Array): Promise<string> {
  const result = await readLevelDbValue(dir, key);
  expect(result.parseFailure).toBeNull();
  return text(result.value);
}

/**
 * Flips a byte inside the given file's first data block, which trips the
 * block's CRC check the same way `sstable.test.ts` does — a generic parse
 * failure, not the unsupported-compression path.
 */
async function corruptFile(filePath: string): Promise<void> {
  const bytes = await readFile(filePath);
  bytes[64] = bytes[64]! ^ 0xff;
  await writeFile(filePath, bytes);
}

async function findLdbName(dir: string): Promise<string> {
  const names = (await readdir(dir)).filter((name) => name.endsWith(".ldb"));
  if (names.length !== 1) throw new Error(`expected one .ldb in ${dir}, got ${names.length}`);
  return names[0]!;
}

/** A fresh directory holding only a corrupted copy of `fixture`'s `.ldb`. */
async function onlyCorruptedTable(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-all-corrupt-"));
  const name = await findLdbName(src);
  await cp(path.join(src, name), path.join(dst, name));
  await corruptFile(path.join(dst, name));
  return dst;
}

/** A copy of `fixture` with its `.ldb` corrupted but every other file intact. */
async function copyWithCorruptedTable(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-mixed-"));
  await cp(src, dst, { recursive: true });
  const name = await findLdbName(dst);
  await corruptFile(path.join(dst, name));
  return dst;
}

async function findLogName(dir: string): Promise<string> {
  const names = (await readdir(dir)).filter((name) => name.endsWith(".log"));
  if (names.length !== 1) throw new Error(`expected one .log in ${dir}, got ${names.length}`);
  return names[0]!;
}

/**
 * A copy of `fixture` with its `.log` corrupted but every other file intact —
 * the mirror image of `copyWithCorruptedTable`. In `superseded` the `.log`
 * holds the *newer* value, so this is the case where the damaged file is the
 * authoritative one and the surviving `.ldb` is stale.
 */
async function copyWithCorruptedLog(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-torn-log-"));
  await cp(src, dst, { recursive: true });
  const target = path.join(dst, await findLogName(dst));
  const bytes = await readFile(target);
  // Byte 8 lands inside the first physical record's payload (the header is 7
  // bytes), so the header still frames a record and the CRC check is what
  // rejects it.
  bytes[8] = bytes[8]! ^ 0xff;
  await writeFile(target, bytes);
  return dst;
}

/** A fresh directory holding only an unmodified copy of `fixture`'s `.ldb`. */
async function onlyGoodTable(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-vanish-"));
  const name = await findLdbName(src);
  await cp(path.join(src, name), path.join(dst, name));
  return dst;
}

/** An unmodified copy of the whole `fixture` directory. */
async function copyDir(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-copy-"));
  await cp(src, dst, { recursive: true });
  return dst;
}

/**
 * Rewrites a real `.ldb`'s index block to declare compression type 99 —
 * neither none (0) nor snappy (1) — and recomputes the block's checksum so
 * it is otherwise well-formed. Unlike `corruptFile`'s byte flip, this must
 * NOT trip the CRC check: the whole point is a block that parses cleanly
 * enough to reach the compression switch and fail there, so the test
 * exercises the unsupported-compression path specifically, not the generic
 * "corrupt block" path already covered above.
 */
async function withUnsupportedCompression(fixture: string): Promise<string> {
  const src = path.join(FIXTURES, fixture);
  const name = await findLdbName(src);
  const bytes = Buffer.from(await readFile(path.join(src, name)));

  const FOOTER_LENGTH = 48;
  const footer = bytes.subarray(bytes.length - FOOTER_LENGTH);
  let pos = 0;
  ({ next: pos } = readVarint64(footer, pos)); // metaindex handle offset
  ({ next: pos } = readVarint64(footer, pos)); // metaindex handle size
  const indexOffset = readVarint64(footer, pos);
  const indexSize = readVarint64(footer, indexOffset.next);
  const compressionByteOffset = indexOffset.value + indexSize.value;

  bytes[compressionByteOffset] = 99;
  const checked = bytes.subarray(indexOffset.value, compressionByteOffset + 1);
  bytes.writeUInt32LE(maskCrc(crc32c(checked)), compressionByteOffset + 1);

  const dst = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-codec-"));
  await writeFile(path.join(dst, name), bytes);
  return dst;
}

describe("readLevelDbValue", () => {
  it("reads a value that lives only in the log", async () => {
    expect(await cleanValue(path.join(FIXTURES, "log-only"), KEY)).toContain("log-only");
  });

  it("reads a value that lives in a compacted table", async () => {
    expect(await cleanValue(path.join(FIXTURES, "compacted"), KEY)).toContain("compacted");
  });

  it("prefers the newer log write over the older compacted value", async () => {
    const value = await cleanValue(path.join(FIXTURES, "superseded"), KEY);
    expect(value).toContain("fresh");
    expect(value).not.toContain("stale");
  });

  it("returns null when the newest record is a deletion", async () => {
    expect((await readLevelDbValue(path.join(FIXTURES, "deleted"), KEY)).value).toBeNull();
  });

  it("returns null for a key that was never written", async () => {
    const absent = Buffer.from("_missing", "latin1");
    expect((await readLevelDbValue(path.join(FIXTURES, "compacted"), absent)).value).toBeNull();
  });

  it("rejects a directory that does not exist", async () => {
    await expect(readLevelDbValue(path.join(FIXTURES, "nope"), KEY)).rejects.toThrow();
  });

  it("throws, rather than returning null, when every file that could hold the key fails to parse", async () => {
    const dir = await onlyCorruptedTable("compacted");
    let caught: unknown;
    try {
      await readLevelDbValue(dir, KEY);
      throw new Error("expected readLevelDbValue to reject");
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(Error);
    const error = caught as Error;
    // Names how many files were skipped, per the design doc's failure table:
    // a parse failure must route to "keep last known-good hosts", not to the
    // "key absent" null that a genuinely unwritten key returns.
    expect(error.message).toMatch(/1 of 1/);
    expect(error.cause).toBeInstanceOf(Error);
  });

  it("still returns the good record when a sibling file is corrupt", async () => {
    const dir = await copyWithCorruptedTable("superseded");
    // The corrupted file is the .ldb holding the stale value; the .log's
    // fresh value must still win, proving a skipped file does not suppress
    // a winner found elsewhere.
    const result = await readLevelDbValue(dir, KEY);
    expect(text(result.value)).toContain("fresh");
    // The good record survives, and the damaged sibling is still reported --
    // the caller applies the hosts *and* shows the detail.
    expect(result.parseFailure).toMatch(/1 of 2/);
  });

  it("reports the damage when the torn file was the one holding the newest value", async () => {
    const dir = await copyWithCorruptedLog("superseded");
    const result = await readLevelDbValue(dir, KEY);

    // The `.log` held `fresh`; only `stale` survives. Returning it is right —
    // it is the best answer left — but returning it *silently* is what let a
    // host the user deleted in the Paseo app stay in the tray, credentials and
    // all, behind a menu with no error row on it.
    expect(text(result.value)).toContain("stale");
    expect(result.parseFailure).toMatch(/1 of 2/);
    expect(result.parseFailure).toMatch(/out of date/);
  });

  it("treats a deletion found next to an unreadable file as undetermined, not as an absent key", async () => {
    const dir = await copyWithCorruptedTable("deleted");
    // The `.log` holds the deletion, so it wins; the corrupted `.ldb` might
    // have held a newer write. "The key is gone" cannot be concluded from a
    // database we could only partly read — that reads as "zero hosts" rather
    // than "keep the last known-good set", which is the wrong row entirely.
    await expect(readLevelDbValue(dir, KEY)).rejects.toThrow(/could not be determined/);
  });

  it("scans a table named with the legacy .sst extension", async () => {
    const src = path.join(FIXTURES, "compacted");
    const dir = await mkdtemp(path.join(os.tmpdir(), "leveldb-reader-sst-"));
    await cp(path.join(src, await findLdbName(src)), path.join(dir, "000005.sst"));

    expect(await cleanValue(dir, KEY)).toContain("compacted");
  });

  it("propagates an unsupported compression type instead of treating it as a skippable parse failure", async () => {
    const dir = await withUnsupportedCompression("compacted");
    await expect(readLevelDbValue(dir, KEY)).rejects.toThrow(
      /Unsupported LevelDB compression type 99/,
    );
  });

  it("reports the key as undetermined, not absent, when the only relevant file keeps vanishing", async () => {
    const dir = await onlyGoodTable("compacted");
    const target = path.join(dir, await findLdbName(dir));
    // Persists: a queue of length 1 is reused on every call, so every scan
    // sees the file as gone.
    readFileQueues.set(target, [async () => { throw enoentError(target); }]);

    // The listing named a file that could hold the key and we never got to
    // read it. "Absent" would send the tray to zero hosts; the truth is that
    // the value could not be determined, which keeps the last good set.
    await expect(readLevelDbValue(dir, KEY)).rejects.toThrow(/could not be determined/);
  });

  it("returns the good record with a warning when a sibling file keeps vanishing", async () => {
    const dir = await copyDir("superseded");
    // The .ldb (holding the stale value) vanishes on every read; the .log's
    // fresh value still wins. But a listing that never settles is a listing
    // we cannot vouch for, so the value comes back flagged.
    const ldbTarget = path.join(dir, await findLdbName(dir));
    readFileQueues.set(ldbTarget, [async () => { throw enoentError(ldbTarget); }]);

    const result = await readLevelDbValue(dir, KEY);
    expect(text(result.value)).toContain("fresh");
    expect(result.parseFailure).toMatch(/out of date/);
  });

  it("lists again when the newer file vanished, instead of returning the older survivor as current", async () => {
    const dir = await copyDir("superseded");
    // The .log holds `fresh`; the .ldb holds `stale`. Make the .log vanish on
    // the first read only -- the shape of a memtable flush that unlinked it
    // after writing its records to a table the first listing never saw. A
    // reader that only re-lists when it found *nothing* would hand back
    // `stale` with no signal, since the .ldb produced a winner.
    const logTarget = path.join(dir, await findLogName(dir));
    const goodBytes = await readFile(logTarget);
    readFileQueues.set(logTarget, [
      async () => {
        throw enoentError(logTarget);
      },
      async () => goodBytes,
    ]);

    expect(await cleanValue(dir, KEY)).toContain("fresh");
  });

  it("treats a read error other than ENOENT as damage, not as a vanished file", async () => {
    const dir = await onlyGoodTable("compacted");
    const target = path.join(dir, await findLdbName(dir));
    readFileQueues.set(target, [async () => { throw fsError("EACCES", target); }]);

    // A file we were refused says nothing about where its data went. Calling
    // it "vanished" and then "absent" is how a permission problem turned into
    // an applied empty host set.
    let caught: unknown;
    try {
      await readLevelDbValue(dir, KEY);
      throw new Error("expected readLevelDbValue to reject");
    } catch (error) {
      caught = error;
    }
    expect((caught as Error).message).toMatch(/could not be determined/);
    expect(((caught as Error).cause as NodeJS.ErrnoException).code).toBe("EACCES");
  });

  it("finds the record on the retried scan after the first scan saw the file vanish", async () => {
    const dir = await onlyGoodTable("compacted");
    const target = path.join(dir, await findLdbName(dir));
    const goodBytes = await readFile(target); // passes through: no queue set yet

    // First call: looks vanished. Second call (the retry): succeeds. If the
    // retry were missing or broken, this test — not the "still returns...
    // vanished" test above, which never needs a retry — is the one that
    // would catch it.
    readFileQueues.set(target, [
      async () => {
        throw enoentError(target);
      },
      async () => goodBytes,
    ]);

    const value = await cleanValue(dir, KEY);
    expect(value).toContain("compacted");
  });
});
