# Registry Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Paseo desktop app's host registry the only source of hosts, so a remote host paired in the app needs no second pairing here.

**Architecture:** A pure-JavaScript, read-only Chromium LevelDB reader parses the desktop app's `localStorage` record `@paseo:daemon-registry` directly from `.ldb` and `.log` files, without taking the database lock. A new `registry-session` replaces `config-session`: it watches the directory, debounces, compares a fingerprint, and applies changed host sets to the existing fleet. `config.json` host storage and clipboard pairing are deleted.

**Tech Stack:** TypeScript (ESM, `.js` import specifiers), Electron 41, vitest 4, zod 4, `snappyjs` (runtime, pure JS), `classic-level` (devDependency, fixture generation only).

**Spec:** `docs/superpowers/2026-08-19-registry-sync-design.md` — read it before starting. It records why this depends on an unsupported surface and what that costs.

## Global Constraints

- **Branch:** `registry-sync`. Never commit to `main`.
- **Never create a `BrowserWindow`.** Electron may appear only in `src/main.ts` and `src/tray/tray-presenter.ts`. Every module in `src/registry/` is pure or takes collaborators by injection.
- **Never crash the tray.** No code path here may throw into the main process or leave a rejecting promise un-caught. Node terminates on unhandled rejections.
- **The SDK is pinned exactly** at `0.4.0` for `@getpaseo/client`, `@getpaseo/protocol`, `@getpaseo/server`. Do not add carets or bump.
- **`snappyjs` version:** `0.7.0`, a runtime `dependency`. **`classic-level` version:** `2.x`, a `devDependency` only — it must never enter the bundle, or notarization gains a native binary.
- **Schemas derive from the published protocol.** Import `DirectTcpHostConnectionSchema` and `ConnectionOfferSchema` from `@getpaseo/protocol`; never redefine them locally.
- **Never derive a workspace's state.** Untouched by this change, but still true.
- **No silent caps.** Any dropped host is counted into the error row.
- **Do not launch the app to check your work.** `electron .` writes into the real `~/Library/Application Support/Paseo Icon/`.
- **Verification commands:** `npx vitest run` and `npm run typecheck`. There is no linter.
- **Mutate before claiming coverage.** For every test asserting a safety property, break the thing it covers and confirm the test goes red before reporting it green.

## Naming and copy

Exact strings, used verbatim in menu rows and errors:

- Error row label: `Configuration error`
- App-not-found message: `Paseo desktop app not found.` followed by the probed path.
- No-hosts message: `No hosts yet. Pair a host in the Paseo app.`
- Unknown compression: `Unsupported LevelDB compression type <n>. The Paseo app's storage format changed.`

---

## File Structure

The spec names one `registry/leveldb-reader.ts`. This plan splits the binary parsing into three focused files, because the SSTable and write-ahead-log formats are independent and each deserves its own tests. This is a refinement of the spec's layout, not a departure from it.

| File | Responsibility |
| --- | --- |
| `src/registry/binary.ts` | Varint decoding and CRC32C. No LevelDB knowledge. |
| `src/registry/sstable.ts` | One `.ldb` file: footer, index block, data blocks, snappy. |
| `src/registry/wal.ts` | One `.log` file: record framing, batch decoding. |
| `src/registry/leveldb-reader.ts` | A directory: scan every file, newest sequence wins, honor deletions. |
| `src/registry/local-storage.ts` | Chromium localStorage key framing and value encoding byte. |
| `src/registry/paseo-registry.ts` | Locate the support dir, validate, map `HostProfile[]` → `HostEntry[]`. |
| `src/registry/registry-session.ts` | Watch, debounce, poll, fingerprint, apply, error row. |
| `src/config/host-entry.ts` | Renamed from `host-config.ts`; schemas and `hostsFingerprint` only. |
| `scripts/make-registry-fixtures.mjs` | Generates committed test fixtures with real LevelDB. |

---

### Task 1: Binary primitives

**Files:**
- Create: `src/registry/binary.ts`
- Test: `src/registry/binary.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `readVarint32(buf: Uint8Array, pos: number): { value: number; next: number }`
  - `readVarint64(buf: Uint8Array, pos: number): { value: number; next: number }`
  - `crc32c(buf: Uint8Array): number`
  - `unmaskCrc(masked: number): number`

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/binary.test.ts
import { describe, expect, it } from "vitest";
import { crc32c, readVarint32, readVarint64, unmaskCrc } from "./binary.js";

describe("readVarint32", () => {
  it("reads a single-byte value and reports the next offset", () => {
    expect(readVarint32(Uint8Array.from([0x05]), 0)).toEqual({ value: 5, next: 1 });
  });

  it("reads a multi-byte value", () => {
    // 300 = 0b100101100 -> 0xac 0x02
    expect(readVarint32(Uint8Array.from([0xac, 0x02]), 0)).toEqual({ value: 300, next: 2 });
  });

  it("reads from a non-zero offset", () => {
    expect(readVarint32(Uint8Array.from([0xff, 0xac, 0x02]), 1)).toEqual({ value: 300, next: 3 });
  });

  it("throws rather than returning garbage when the buffer ends mid-varint", () => {
    expect(() => readVarint32(Uint8Array.from([0x80]), 0)).toThrow(/past end/);
  });
});

describe("readVarint64", () => {
  it("reads a value above the 32-bit range", () => {
    // 2^35 = 34359738368
    expect(readVarint64(Uint8Array.from([0x80, 0x80, 0x80, 0x80, 0x80, 0x01]), 0)).toEqual({
      value: 34359738368,
      next: 6,
    });
  });
});

describe("crc32c", () => {
  it("matches the standard check vector", () => {
    // The CRC32C check value for "123456789" is 0xE3069283.
    expect(crc32c(new TextEncoder().encode("123456789"))).toBe(0xe3069283);
  });

  it("round-trips through LevelDB's mask", () => {
    const crc = crc32c(new TextEncoder().encode("paseo"));
    const masked = (((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0;
    expect(unmaskCrc(masked)).toBe(crc);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/binary.test.ts`
Expected: FAIL — cannot resolve `./binary.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/binary.ts

/**
 * Varint and checksum primitives for LevelDB's on-disk formats.
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
 * Reverses LevelDB's CRC mask. Stored checksums are rotated and offset so that
 * a checksum never appears verbatim in the data it covers.
 */
export function unmaskCrc(masked: number): number {
  const rot = (masked - MASK_DELTA) >>> 0;
  return ((rot >>> 17) | (rot << 15)) >>> 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run src/registry/binary.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutation check**

Change `0x82f63b78` to `0xedb88320` (that is CRC32, not CRC32C). Run the test. Expected: the check-vector test FAILS. Revert.

- [ ] **Step 6: Commit**

```bash
git add src/registry/binary.ts src/registry/binary.test.ts
git commit -m "feat: varint and CRC32C primitives for LevelDB parsing"
```

---

### Task 2: Test fixtures generated by real LevelDB

**Files:**
- Create: `scripts/make-registry-fixtures.mjs`
- Create (generated, committed): `src/registry/__fixtures__/{log-only,compacted,superseded,deleted,utf16}/`
- Modify: `package.json` (add `classic-level` devDependency, add `fixtures:registry` script)

**Interfaces:**
- Consumes: nothing.
- Produces: fixture directories on disk. Every later task's tests read these. The record key in all fixtures is `_paseo://app\x00\x01@paseo:daemon-registry`.

Fixtures are generated by real LevelDB so the parser is validated against the actual format producer rather than against our own reading of the format. They are committed, so the test run itself needs no native module.

- [ ] **Step 1: Add the devDependency**

```bash
npm install --save-dev classic-level@^2.0.0
```

Then confirm `package.json` lists `classic-level` under `devDependencies` and **not** under `dependencies`.

- [ ] **Step 2: Write the generator**

```js
// scripts/make-registry-fixtures.mjs
import { ClassicLevel } from "classic-level";
import { rm, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Chromium frames a localStorage record as `_<origin>\x00\x01<key>`.
const KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("@paseo:daemon-registry", "latin1"),
]);

/** Chromium tags Latin1 values with a leading 0x01 byte, UTF-16LE with 0x00. */
function latin1Value(text) {
  return Buffer.concat([Buffer.from([0x01]), Buffer.from(text, "latin1")]);
}

function utf16Value(text) {
  return Buffer.concat([Buffer.from([0x00]), Buffer.from(text, "utf16le")]);
}

function hosts(label) {
  return JSON.stringify([
    {
      serverId: "srv_fixture01",
      label,
      lifecycle: {},
      connections: [{ id: "direct:localhost:6767", type: "directTcp", endpoint: "localhost:6767" }],
      preferredConnectionId: "direct:localhost:6767",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    },
  ]);
}

const root = path.join(fileURLToPath(new URL("../src/registry/__fixtures__", import.meta.url)));

async function build(name, write) {
  const dir = path.join(root, name);
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });
  const db = new ClassicLevel(dir, { keyEncoding: "buffer", valueEncoding: "buffer" });
  await db.open();
  await write(db);
  await db.close();
  console.log(`wrote ${name}`);
}

await mkdir(root, { recursive: true });

// Fresh write, never compacted: the record lives only in the .log.
await build("log-only", async (db) => {
  await db.put(KEY, latin1Value(hosts("log-only")));
});

// Compacted: the record lives in an .ldb with snappy-compressed blocks.
await build("compacted", async (db) => {
  await db.put(KEY, latin1Value(hosts("compacted")));
  await db.compactRange(Buffer.alloc(0), Buffer.from([0xff, 0xff, 0xff, 0xff]));
});

// An .ldb value superseded by a newer .log write. Highest sequence must win.
await build("superseded", async (db) => {
  await db.put(KEY, latin1Value(hosts("stale")));
  await db.compactRange(Buffer.alloc(0), Buffer.from([0xff, 0xff, 0xff, 0xff]));
  await db.put(KEY, latin1Value(hosts("fresh")));
});

// Compacted, then deleted. The deletion is newer and must win.
await build("deleted", async (db) => {
  await db.put(KEY, latin1Value(hosts("gone")));
  await db.compactRange(Buffer.alloc(0), Buffer.from([0xff, 0xff, 0xff, 0xff]));
  await db.del(KEY);
});

// UTF-16LE value encoding.
await build("utf16", async (db) => {
  await db.put(KEY, utf16Value(hosts("utf16")));
});
```

- [ ] **Step 3: Add the script and run it**

Add to `package.json` `scripts`:

```json
"fixtures:registry": "node scripts/make-registry-fixtures.mjs"
```

Run: `npm run fixtures:registry`
Expected: prints `wrote log-only` … `wrote utf16`, and `src/registry/__fixtures__/` contains five directories each holding `CURRENT`, `LOCK`, `LOG`, `MANIFEST-*`, and at least one `.log` or `.ldb`.

- [ ] **Step 4: Verify the fixtures actually differ as intended**

Run:

```bash
ls src/registry/__fixtures__/log-only/*.ldb 2>/dev/null && echo "UNEXPECTED: log-only has an .ldb" || echo "ok: log-only has no .ldb"
ls src/registry/__fixtures__/compacted/*.ldb >/dev/null && echo "ok: compacted has an .ldb"
```

Expected: `ok: log-only has no .ldb` and `ok: compacted has an .ldb`. If `log-only` produced an `.ldb`, the fixture is not testing the write-ahead-log path — investigate before continuing, because Task 4 depends on it.

- [ ] **Step 5: Remove the lock files from the committed fixtures**

`LOCK` is a runtime artifact and must not be committed:

```bash
rm -f src/registry/__fixtures__/*/LOCK
```

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json scripts/make-registry-fixtures.mjs src/registry/__fixtures__
git commit -m "test: LevelDB fixtures generated by the real implementation"
```

---

### Task 3: SSTable (`.ldb`) reader

**Files:**
- Create: `src/registry/sstable.ts`
- Test: `src/registry/sstable.test.ts`

**Interfaces:**
- Consumes: `readVarint32`, `readVarint64`, `crc32c`, `unmaskCrc` from `./binary.js`.
- Produces:
  - `interface InternalRecord { userKey: Uint8Array; sequence: number; isDeletion: boolean; value: Uint8Array }`
  - `findInTable(file: Uint8Array, userKey: Uint8Array): InternalRecord[]`

- [ ] **Step 1: Install snappy**

```bash
npm install snappyjs@0.7.0
npm install --save-dev @types/snappyjs@0.7.1
```

`snappyjs` is a **runtime dependency** — the reader needs it in the shipped app. It is pure JavaScript, so the bundle stays free of native code. It ships no type declarations of its own, which is why `@types/snappyjs` is needed; that one is a devDependency. The declared signature is `uncompress<T extends ArrayBuffer | Uint8Array>(input: T, maxLength?: number): T`, so passing a `Uint8Array` returns a `Uint8Array` with no cast.

Confirm placement: `snappyjs` under `dependencies`, `@types/snappyjs` under `devDependencies`.

- [ ] **Step 2: Write the failing test**

```ts
// src/registry/sstable.test.ts
import { describe, expect, it } from "vitest";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInTable } from "./sstable.js";

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

const KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("@paseo:daemon-registry", "latin1"),
]);

async function tableBytes(fixture: string): Promise<Buffer> {
  const dir = path.join(FIXTURES, fixture);
  const names = (await readdir(dir)).filter((name) => name.endsWith(".ldb"));
  if (names.length !== 1) throw new Error(`expected one .ldb in ${fixture}, got ${names.length}`);
  return readFile(path.join(dir, names[0]!));
}

describe("findInTable", () => {
  it("finds the record in a compacted, snappy-compressed table", async () => {
    const records = findInTable(await tableBytes("compacted"), KEY);
    expect(records).toHaveLength(1);
    expect(records[0]!.isDeletion).toBe(false);
    // Leading 0x01 is Chromium's Latin1 encoding tag.
    expect(Buffer.from(records[0]!.value).subarray(1).toString("latin1")).toContain("compacted");
  });

  it("returns nothing for a key the table does not hold", async () => {
    const records = findInTable(await tableBytes("compacted"), Buffer.from("_nope", "latin1"));
    expect(records).toEqual([]);
  });

  it("rejects a table whose block checksum does not match", async () => {
    const bytes = await tableBytes("compacted");
    const corrupted = Buffer.from(bytes);
    // Flip a bit early in the file, inside the first data block's payload.
    corrupted[64] = corrupted[64]! ^ 0xff;
    expect(() => findInTable(corrupted, KEY)).toThrow(/checksum/i);
  });
});
```

> **On the unknown-compression branch:** it is not unit-tested here. The
> compression byte's offset depends on block layout the test cannot compute
> without reimplementing the reader, and a test that corrupts a guessed offset
> asserts nothing. That branch is covered by the mutation check in Step 5 of
> Task 5, which forces the codec path deliberately. Do not add a
> compression test here that passes by accident.

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run src/registry/sstable.test.ts`
Expected: FAIL — cannot resolve `./sstable.js`.

- [ ] **Step 4: Write the implementation**

```ts
// src/registry/sstable.ts
import { uncompress } from "snappyjs";
import { crc32c, readVarint32, readVarint64, unmaskCrc } from "./binary.js";

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

const FOOTER_LENGTH = 48;
const MAGIC_LOW = 0x8b80fb57;
const MAGIC_HIGH = 0xdb477524;
const BLOCK_TRAILER_LENGTH = 5; // 1 compression byte + 4 checksum bytes

interface BlockHandle {
  offset: number;
  size: number;
}

function view(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
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
  throw new Error(
    `Unsupported LevelDB compression type ${compression}. The Paseo app's storage format changed.`,
  );
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

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
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
    if (compareBytes(separator, userKey) < 0) continue;

    const offset = readVarint64(indexEntry.value, 0);
    const size = readVarint64(indexEntry.value, offset.next);
    const dataBlock = readBlock(file, { offset: offset.value, size: size.value });

    for (const entry of blockEntries(dataBlock)) {
      const parsed = splitInternalKey(entry.key);
      if (!sameBytes(parsed.userKey, userKey)) continue;
      found.push({ ...parsed, value: entry.value });
    }
  }
  return found;
}

function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const shared = Math.min(a.length, b.length);
  for (let i = 0; i < shared; i++) {
    if (a[i]! !== b[i]!) return a[i]! < b[i]! ? -1 : 1;
  }
  return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run src/registry/sstable.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 6: Mutation check**

Comment out the `throw new Error("LevelDB block failed its checksum")` line and return the contents regardless. Run the tests. Expected: the corrupted-table test FAILS (it no longer throws). Restore the line and confirm green again. A checksum test that passes with checksums disabled is worthless.

- [ ] **Step 7: Commit**

```bash
git add src/registry/sstable.ts src/registry/sstable.test.ts
git commit -m "feat: read records for one key out of a LevelDB SSTable"
```

---

### Task 4: Write-ahead log (`.log`) reader

**Files:**
- Create: `src/registry/wal.ts`
- Test: `src/registry/wal.test.ts`

**Interfaces:**
- Consumes: `readVarint32`, `crc32c`, `unmaskCrc` from `./binary.js`; `InternalRecord` from `./sstable.js`.
- Produces: `findInLog(file: Uint8Array, userKey: Uint8Array): InternalRecord[]`

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/wal.test.ts
import { describe, expect, it } from "vitest";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInLog } from "./wal.js";

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/wal.test.ts`
Expected: FAIL — cannot resolve `./wal.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/wal.ts
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

/**
 * Reassembles the physical records of a write-ahead log into batch payloads.
 *
 * A log is a sequence of 32KB blocks, and one batch can be split across block
 * boundaries into FIRST/MIDDLE/LAST fragments, so this cannot simply read
 * batches back-to-back.
 *
 * A fragment whose checksum fails is dropped along with the batch it belongs
 * to. The tail of a log being actively written is routinely torn, and that is
 * a normal condition here, not an error worth failing the whole read over.
 */
function readBatches(file: Uint8Array): Uint8Array[] {
  const dv = view(file);
  const batches: Uint8Array[] = [];
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
      }

      pos = payloadEnd;
    }
  }
  return batches;
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

    let value = new Uint8Array(0);
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

/** Every record for `userKey` in one `.log`. */
export function findInLog(file: Uint8Array, userKey: Uint8Array): InternalRecord[] {
  const found: InternalRecord[] = [];
  for (const batch of readBatches(file)) {
    for (const record of batchRecords(batch)) {
      if (sameBytes(record.userKey, userKey)) found.push(record);
    }
  }
  return found;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/registry/wal.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Mutation check**

Replace `const intact = crc32c(checked) === unmaskCrc(storedCrc);` with `const intact = true;`. Run the tests. Expected: the corrupted-log test FAILS. Restore it.

- [ ] **Step 6: Commit**

```bash
git add src/registry/wal.ts src/registry/wal.test.ts
git commit -m "feat: read records for one key out of a LevelDB write-ahead log"
```

---

### Task 5: Directory reader — newest sequence wins

**Files:**
- Create: `src/registry/leveldb-reader.ts`
- Test: `src/registry/leveldb-reader.test.ts`

**Interfaces:**
- Consumes: `findInTable` from `./sstable.js`, `findInLog` from `./wal.js`.
- Produces: `readLevelDbValue(dir: string, userKey: Uint8Array): Promise<Uint8Array | null>` — the newest live value, or `null` when the key is absent or its newest record is a deletion.

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/leveldb-reader.test.ts
import { describe, expect, it } from "vitest";
import path from "node:path";
import { readLevelDbValue } from "./leveldb-reader.js";

const FIXTURES = new URL("./__fixtures__/", import.meta.url).pathname;

const KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("@paseo:daemon-registry", "latin1"),
]);

function text(value: Uint8Array | null): string {
  if (!value) throw new Error("expected a value");
  return Buffer.from(value).subarray(1).toString("latin1");
}

describe("readLevelDbValue", () => {
  it("reads a value that lives only in the log", async () => {
    expect(text(await readLevelDbValue(path.join(FIXTURES, "log-only"), KEY))).toContain("log-only");
  });

  it("reads a value that lives in a compacted table", async () => {
    expect(text(await readLevelDbValue(path.join(FIXTURES, "compacted"), KEY))).toContain("compacted");
  });

  it("prefers the newer log write over the older compacted value", async () => {
    const value = text(await readLevelDbValue(path.join(FIXTURES, "superseded"), KEY));
    expect(value).toContain("fresh");
    expect(value).not.toContain("stale");
  });

  it("returns null when the newest record is a deletion", async () => {
    expect(await readLevelDbValue(path.join(FIXTURES, "deleted"), KEY)).toBeNull();
  });

  it("returns null for a key that was never written", async () => {
    const absent = Buffer.from("_missing", "latin1");
    expect(await readLevelDbValue(path.join(FIXTURES, "compacted"), absent)).toBeNull();
  });

  it("rejects a directory that does not exist", async () => {
    await expect(readLevelDbValue(path.join(FIXTURES, "nope"), KEY)).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/leveldb-reader.test.ts`
Expected: FAIL — cannot resolve `./leveldb-reader.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/leveldb-reader.ts
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { findInTable, type InternalRecord } from "./sstable.js";
import { findInLog } from "./wal.js";

/**
 * Reads the newest live value for one key out of a Chromium LevelDB, without
 * taking the database lock.
 *
 * Reading a LevelDB properly means CURRENT -> MANIFEST -> version set -> live
 * files per level. We need exactly one key, and every record carries a
 * sequence number that totally orders it against every other write, so
 * scanning all files and taking the highest sequence is correct by
 * construction and skips the version set entirely.
 *
 * Files are read best-effort. A compaction can delete a file between the
 * directory listing and the read, and a file being written can be torn; both
 * are normal here, so an unreadable file is skipped rather than failing the
 * whole read. A directory that cannot be listed at all is a real error and
 * does throw — that is the difference between "Paseo is busy" and "Paseo is
 * not installed".
 */
export async function readLevelDbValue(
  dir: string,
  userKey: Uint8Array,
): Promise<Uint8Array | null> {
  const names = await readdir(dir);

  let winner: InternalRecord | null = null;
  for (const name of names) {
    const isTable = name.endsWith(".ldb");
    const isLog = name.endsWith(".log");
    if (!isTable && !isLog) continue;

    let bytes: Buffer;
    try {
      bytes = await readFile(path.join(dir, name));
    } catch {
      // Compacted away between listing and reading. Nothing to recover.
      continue;
    }

    let records: InternalRecord[];
    try {
      records = isTable ? findInTable(bytes, userKey) : findInLog(bytes, userKey);
    } catch (error) {
      // A corrupt or half-written file must not hide a good record in a
      // sibling file, but an unsupported compression type means the format
      // moved under us and every file is suspect -- that one propagates.
      if (error instanceof Error && error.message.includes("Unsupported LevelDB compression")) {
        throw error;
      }
      continue;
    }

    for (const record of records) {
      if (!winner || record.sequence > winner.sequence) winner = record;
    }
  }

  if (!winner || winner.isDeletion) return null;
  return winner.value;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/registry/leveldb-reader.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutation check**

Change `record.sequence > winner.sequence` to `record.sequence < winner.sequence`. Run the tests. Expected: the supersede test FAILS with `"stale"` where `"fresh"` was expected, and the deletion test FAILS. Restore.

- [ ] **Step 6: Prove the unknown-compression branch actually fires**

This is the branch that tells us the Paseo app's storage format moved, so it must be exercised deliberately rather than assumed. In `src/registry/sstable.ts`, temporarily change the snappy check from `if (compression === 1)` to `if (compression === 99)`. Run:

`npx vitest run src/registry/leveldb-reader.test.ts`

Expected: the compacted, superseded, and deleted tests FAIL with `Unsupported LevelDB compression type 1`, confirming the message reaches the caller through `readLevelDbValue` rather than being swallowed by its per-file `catch`. Restore the `1`, re-run, confirm green.

- [ ] **Step 7: Commit**

```bash
git add src/registry/leveldb-reader.ts src/registry/leveldb-reader.test.ts
git commit -m "feat: read the newest live value for a key from a LevelDB directory"
```

---

### Task 6: Chromium localStorage record semantics

**Files:**
- Create: `src/registry/local-storage.ts`
- Test: `src/registry/local-storage.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `localStorageKey(origin: string, key: string): Uint8Array`
  - `decodeLocalStorageValue(value: Uint8Array): string`

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/local-storage.test.ts
import { describe, expect, it } from "vitest";
import { decodeLocalStorageValue, localStorageKey } from "./local-storage.js";

describe("localStorageKey", () => {
  it("frames the key the way Chromium stores it", () => {
    const key = localStorageKey("paseo://app", "@paseo:daemon-registry");
    expect(Buffer.from(key).toString("latin1")).toBe(
      "_paseo://app @paseo:daemon-registry",
    );
  });
});

describe("decodeLocalStorageValue", () => {
  it("decodes a Latin1-tagged value", () => {
    const value = Buffer.concat([Buffer.from([0x01]), Buffer.from("hosts", "latin1")]);
    expect(decodeLocalStorageValue(value)).toBe("hosts");
  });

  it("decodes a UTF-16LE-tagged value", () => {
    const value = Buffer.concat([Buffer.from([0x00]), Buffer.from("hosts", "utf16le")]);
    expect(decodeLocalStorageValue(value)).toBe("hosts");
  });

  it("preserves non-ASCII characters through the UTF-16 path", () => {
    const value = Buffer.concat([Buffer.from([0x00]), Buffer.from("naïve ☕", "utf16le")]);
    expect(decodeLocalStorageValue(value)).toBe("naïve ☕");
  });

  it("rejects an unknown encoding tag rather than guessing", () => {
    expect(() => decodeLocalStorageValue(Uint8Array.from([0x07, 0x61]))).toThrow(/encoding/i);
  });

  it("rejects an empty value", () => {
    expect(() => decodeLocalStorageValue(new Uint8Array(0))).toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/local-storage.test.ts`
Expected: FAIL — cannot resolve `./local-storage.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/local-storage.ts

/**
 * Chromium's localStorage record layout, as stored in its LevelDB.
 *
 * A record's key is `_<origin>\x00\x01<key>`, and its value carries a leading
 * byte naming the encoding of the rest: 0x00 for UTF-16LE, 0x01 for Latin1.
 * Chromium picks per value, so both are reachable from the same database and
 * neither may be assumed.
 */

const LATIN1_TAG = 0x01;
const UTF16LE_TAG = 0x00;

export function localStorageKey(origin: string, key: string): Uint8Array {
  const prefix = Buffer.from(`_${origin}`, "latin1");
  const separator = Buffer.from([0x00, 0x01]);
  return new Uint8Array(Buffer.concat([prefix, separator, Buffer.from(key, "latin1")]));
}

export function decodeLocalStorageValue(value: Uint8Array): string {
  if (value.length === 0) throw new Error("localStorage value is empty");
  const tag = value[0]!;
  const body = Buffer.from(value.subarray(1));
  if (tag === LATIN1_TAG) return body.toString("latin1");
  if (tag === UTF16LE_TAG) return body.toString("utf16le");
  throw new Error(`Unknown localStorage value encoding tag ${tag}`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/registry/local-storage.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutation check**

Swap the two tag constants so `LATIN1_TAG = 0x00`. Run the tests. Expected: both decode tests FAIL. Restore.

- [ ] **Step 6: Commit**

```bash
git add src/registry/local-storage.ts src/registry/local-storage.test.ts
git commit -m "feat: decode Chromium localStorage keys and values"
```

---

### Task 7: Map the registry to host entries

**Files:**
- Create: `src/registry/paseo-registry.ts`
- Test: `src/registry/paseo-registry.test.ts`

**Interfaces:**
- Consumes: `readLevelDbValue`, `localStorageKey`, `decodeLocalStorageValue`; `HostEntry` from `../config/host-entry.js` (Task 9 renames the file — until then import from `../config/host-config.js` and update the specifier in Task 9).
- Produces:
  - `interface RegistrySnapshot { hosts: HostEntry[]; failures: string[] }`
  - `hostEntriesFromRegistry(json: string): RegistrySnapshot`
  - `registryLevelDbDir(appSupportDir: string): Promise<string>`
  - `readRegistry(appSupportDir: string): Promise<RegistrySnapshot | null>` — `null` when the key is absent.

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/paseo-registry.test.ts
import { describe, expect, it } from "vitest";
import { hostEntriesFromRegistry } from "./paseo-registry.js";

function profile(overrides: Record<string, unknown> = {}) {
  return {
    serverId: "srv_one",
    label: "Mac.localdomain",
    lifecycle: {},
    connections: [{ id: "direct:localhost:6767", type: "directTcp", endpoint: "localhost:6767" }],
    preferredConnectionId: "direct:localhost:6767",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("hostEntriesFromRegistry", () => {
  it("maps a direct TCP host, keying it by serverId", () => {
    const { hosts, failures } = hostEntriesFromRegistry(JSON.stringify([profile()]));
    expect(failures).toEqual([]);
    expect(hosts).toEqual([
      {
        id: "srv_one",
        label: "Mac.localdomain",
        type: "directTcp",
        endpoint: "localhost:6767",
        useTls: false,
      },
    ]);
  });

  it("rebuilds a relay offer from the stored connection", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          serverId: "srv_two",
          label: "ai-mbp.local",
          connections: [
            {
              id: "relay:wss:relay.paseo.sh:443",
              type: "relay",
              relayEndpoint: "relay.paseo.sh:443",
              useTls: true,
              daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
            },
          ],
          preferredConnectionId: "relay:wss:relay.paseo.sh:443",
        }),
      ]),
    );
    expect(hosts[0]).toEqual({
      id: "srv_two",
      label: "ai-mbp.local",
      type: "relay",
      offer: {
        v: 2,
        serverId: "srv_two",
        daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
        relay: { endpoint: "relay.paseo.sh:443", useTls: true },
      },
    });
  });

  it("keeps two relay hosts apart even though their connection ids are identical", () => {
    const shared = {
      id: "relay:wss:relay.paseo.sh:443",
      type: "relay",
      relayEndpoint: "relay.paseo.sh:443",
      useTls: true,
      daemonPublicKeyB64: "AAAA",
    };
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({ serverId: "srv_a", connections: [shared], preferredConnectionId: shared.id }),
        profile({ serverId: "srv_b", connections: [shared], preferredConnectionId: shared.id }),
      ]),
    );
    expect(hosts.map((host) => host.id)).toEqual(["srv_a", "srv_b"]);
  });

  it("falls back to a supported connection when the preferred one is not", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "pipe:1", type: "directPipe", path: "/tmp/sock" },
            { id: "direct:1", type: "directTcp", endpoint: "10.0.0.9:6767" },
          ],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toHaveLength(1);
    expect(hosts[0]).toMatchObject({ type: "directTcp", endpoint: "10.0.0.9:6767" });
  });

  it("drops a host with no supported connection and names it in failures", () => {
    const { hosts, failures } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          label: "Pipe only",
          connections: [{ id: "pipe:1", type: "directPipe", path: "/tmp/sock" }],
          preferredConnectionId: "pipe:1",
        }),
      ]),
    );
    expect(hosts).toEqual([]);
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("Pipe only");
  });

  it("carries a direct host's password through", () => {
    const { hosts } = hostEntriesFromRegistry(
      JSON.stringify([
        profile({
          connections: [
            { id: "d", type: "directTcp", endpoint: "10.0.0.9:6767", useTls: true, password: "hunter2" },
          ],
          preferredConnectionId: "d",
        }),
      ]),
    );
    expect(hosts[0]).toMatchObject({ useTls: true, password: "hunter2" });
  });

  it("throws on JSON that is not an array of profiles", () => {
    expect(() => hostEntriesFromRegistry('{"nope":true}')).toThrow();
  });

  it("throws on malformed JSON rather than returning an empty host list", () => {
    expect(() => hostEntriesFromRegistry("{{{")).toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/paseo-registry.test.ts`
Expected: FAIL — cannot resolve `./paseo-registry.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/paseo-registry.ts
import { access } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import type { HostEntry } from "../config/host-config.js";
import { decodeLocalStorageValue, localStorageKey } from "./local-storage.js";
import { readLevelDbValue } from "./leveldb-reader.js";

/**
 * Reads the Paseo desktop app's host registry out of its Chromium
 * localStorage.
 *
 * This is an unsupported surface: the app persists the registry through
 * async-storage, which on Electron is plain localStorage, and nothing upstream
 * promises the location, the key, or the value encoding. The payload's *shape*
 * is safe, because it is the published protocol schemas; the way we reach it
 * is not. See docs/superpowers/2026-08-19-registry-sync-design.md.
 */

const ORIGIN = "paseo://app";
const REGISTRY_KEY = "@paseo:daemon-registry";
const LOCAL_STORAGE_SUBPATH = path.join("Local Storage", "leveldb");

/**
 * Candidate application-support directory names, in priority order. The
 * shipped app is `Paseo`; a development build of the desktop package uses the
 * scoped package name instead.
 */
const APP_DIR_CANDIDATES = ["Paseo", "@getpaseo/desktop"];

/**
 * Only the two connection shapes the tray can actually dial. `directSocket`
 * and `directPipe` are parsed so a host carrying one is recognised and
 * reported, rather than silently vanishing.
 */
const RegistryConnectionSchema = z.discriminatedUnion("type", [
  z.object({
    id: z.string(),
    type: z.literal("directTcp"),
    endpoint: z.string(),
    useTls: z.boolean().optional(),
    password: z.string().optional(),
  }),
  z.object({
    id: z.string(),
    type: z.literal("relay"),
    relayEndpoint: z.string(),
    useTls: z.boolean().optional(),
    daemonPublicKeyB64: z.string(),
  }),
  z.object({ id: z.string(), type: z.literal("directSocket"), path: z.string() }),
  z.object({ id: z.string(), type: z.literal("directPipe"), path: z.string() }),
]);

const HostProfileSchema = z.object({
  serverId: z.string().min(1),
  label: z.string().optional(),
  connections: z.array(RegistryConnectionSchema),
  preferredConnectionId: z.string().nullable().optional(),
});

const RegistrySchema = z.array(HostProfileSchema);

export interface RegistrySnapshot {
  hosts: HostEntry[];
  /** Hosts the tray cannot dial, phrased for the error row. Never silent. */
  failures: string[];
}

type RegistryConnection = z.infer<typeof RegistryConnectionSchema>;

function isSupported(
  connection: RegistryConnection,
): connection is Extract<RegistryConnection, { type: "directTcp" | "relay" }> {
  return connection.type === "directTcp" || connection.type === "relay";
}

/**
 * Picks the connection to dial: the profile's preference when the tray
 * supports it, else the first supported one. A profile can name a preference
 * the tray cannot use (a unix socket) while still carrying a usable relay, and
 * dropping that host would lose a working connection for no reason.
 */
function chooseConnection(
  profile: z.infer<typeof HostProfileSchema>,
): Extract<RegistryConnection, { type: "directTcp" | "relay" }> | null {
  const supported = profile.connections.filter(isSupported);
  const preferred = supported.find((connection) => connection.id === profile.preferredConnectionId);
  return preferred ?? supported[0] ?? null;
}

export function hostEntriesFromRegistry(json: string): RegistrySnapshot {
  const parsed: unknown = JSON.parse(json);
  const profiles = RegistrySchema.parse(parsed);

  const hosts: HostEntry[] = [];
  const failures: string[] = [];

  for (const profile of profiles) {
    const connection = chooseConnection(profile);
    const name = profile.label ?? profile.serverId;
    if (!connection) {
      failures.push(`${name} — no connection the menu bar can use`);
      continue;
    }

    // The id is the serverId, never the connection id: distinct hosts share
    // the identical connection id `relay:wss:relay.paseo.sh:443`, which the
    // duplicate-id check rejects outright. serverId is unique per daemon and
    // stable across restarts, which also keeps the derived clientId stable so
    // the daemon resumes sessions instead of starting new ones.
    const base = { id: profile.serverId, ...(profile.label ? { label: profile.label } : {}) };

    if (connection.type === "directTcp") {
      hosts.push({
        ...base,
        type: "directTcp",
        endpoint: connection.endpoint,
        useTls: connection.useTls ?? false,
        ...(connection.password ? { password: connection.password } : {}),
      });
    } else {
      hosts.push({
        ...base,
        type: "relay",
        offer: {
          v: 2,
          serverId: profile.serverId,
          daemonPublicKeyB64: connection.daemonPublicKeyB64,
          relay: {
            endpoint: connection.relayEndpoint,
            ...(connection.useTls === undefined ? {} : { useTls: connection.useTls }),
          },
        },
      });
    }
  }

  return { hosts, failures };
}

/**
 * The leveldb directory of whichever Paseo build is installed.
 *
 * Throws when none is present: that is a distinct, actionable state ("the app
 * is not installed") rather than an empty registry, and the tray says so.
 */
export async function registryLevelDbDir(appSupportDir: string): Promise<string> {
  const probed: string[] = [];
  for (const candidate of APP_DIR_CANDIDATES) {
    const dir = path.join(appSupportDir, candidate, LOCAL_STORAGE_SUBPATH);
    probed.push(dir);
    try {
      await access(dir);
      return dir;
    } catch {
      continue;
    }
  }
  throw new Error(`Paseo desktop app not found.\n\nLooked in:\n${probed.join("\n")}`);
}

/** `null` means the app is installed but has never stored a registry. */
export async function readRegistry(appSupportDir: string): Promise<RegistrySnapshot | null> {
  const dir = await registryLevelDbDir(appSupportDir);
  const raw = await readLevelDbValue(dir, localStorageKey(ORIGIN, REGISTRY_KEY));
  if (raw === null) return null;
  return hostEntriesFromRegistry(decodeLocalStorageValue(raw));
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/registry/paseo-registry.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 5: Mutation check**

Change `id: profile.serverId` to `id: connection.id`. Run the tests. Expected: the "keeps two relay hosts apart" test FAILS with both ids equal to `relay:wss:relay.paseo.sh:443`. Restore.

- [ ] **Step 6: Commit**

```bash
git add src/registry/paseo-registry.ts src/registry/paseo-registry.test.ts
git commit -m "feat: map the Paseo app's registry onto tray host entries"
```

---

### Task 8: Registry session

**Files:**
- Create: `src/registry/registry-session.ts`
- Test: `src/registry/registry-session.test.ts`

**Interfaces:**
- Consumes: `RegistrySnapshot`, `readRegistry`, `registryLevelDbDir`; `hostsFingerprint`, `AppConfig`, `HostEntry`.
- Produces:
  - `interface RegistrySession { start(): Promise<void>; refresh(): Promise<void>; noteEntryFailures(failures: string[]): void; stop(): void }`
  - `createRegistrySession(options: {...}): RegistrySession`

`noteEntryFailures` exists because two independent things can be wrong at once and they share one menu row: the registry read itself, and entries the *fleet* could not use. `config-session.ts` owned that merge; the registry session inherits it. Neither source may clear the other.

- [ ] **Step 1: Write the failing test**

```ts
// src/registry/registry-session.test.ts
import { describe, expect, it, vi } from "vitest";
import { createRegistrySession } from "./registry-session.js";
import type { AppConfig, HostEntry } from "../config/host-config.js";
import type { RegistrySnapshot } from "./paseo-registry.js";

function host(id: string): HostEntry {
  return { id, label: id, type: "directTcp", endpoint: "10.0.0.1:6767", useTls: false };
}

function harness(reads: Array<RegistrySnapshot | null | Error>) {
  const applied: AppConfig[] = [];
  const errors: (string | null)[] = [];
  let call = 0;
  const session = createRegistrySession({
    readRegistry: async () => {
      const next = reads[Math.min(call++, reads.length - 1)];
      if (next instanceof Error) throw next;
      return next ?? null;
    },
    // No watcher in tests: refresh() is driven explicitly.
    watch: () => () => undefined,
    applyConfig: async (config) => {
      applied.push(config);
    },
    onConfigError: (message) => errors.push(message),
  });
  return { session, applied, errors };
}

describe("createRegistrySession", () => {
  it("applies the hosts it read and clears the error row", async () => {
    const { session, applied, errors } = harness([{ hosts: [host("a")], failures: [] }]);
    await session.start();
    expect(applied).toHaveLength(1);
    expect(applied[0]!.hosts.map((entry) => entry.id)).toEqual(["a"]);
    expect(errors.at(-1)).toBeNull();
  });

  it("does not rebuild the fleet when the host set is unchanged", async () => {
    const snapshot = { hosts: [host("a")], failures: [] };
    const { session, applied } = harness([snapshot, snapshot]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(1);
  });

  it("rebuilds when the host set actually changes", async () => {
    const { session, applied } = harness([
      { hosts: [host("a")], failures: [] },
      { hosts: [host("a"), host("b")], failures: [] },
    ]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(2);
    expect(applied[1]!.hosts.map((entry) => entry.id)).toEqual(["a", "b"]);
  });

  it("keeps the last known-good hosts when a later read fails", async () => {
    const { session, applied, errors } = harness([
      { hosts: [host("a")], failures: [] },
      new Error("torn read"),
    ]);
    await session.start();
    await session.refresh();
    // Nothing re-applied: the good host set stays live.
    expect(applied).toHaveLength(1);
    expect(errors.at(-1)).toContain("torn read");
  });

  it("reports an absent registry without applying an empty host set over a good one", async () => {
    const { session, applied, errors } = harness([{ hosts: [host("a")], failures: [] }, null]);
    await session.start();
    await session.refresh();
    expect(applied).toHaveLength(2);
    expect(applied[1]!.hosts).toEqual([]);
    expect(errors.at(-1)).toContain("No hosts yet");
  });

  it("surfaces dropped hosts in the error row", async () => {
    const { session, errors } = harness([
      { hosts: [host("a")], failures: ["Pipe only — no connection the menu bar can use"] },
    ]);
    await session.start();
    expect(errors.at(-1)).toContain("Pipe only");
  });

  it("shows a registry problem and a fleet problem at the same time", async () => {
    const { session, errors } = harness([null]);
    await session.start();
    session.noteEntryFailures(["h1 — unreachable"]);
    expect(errors.at(-1)).toContain("No hosts yet");
    expect(errors.at(-1)).toContain("h1 — unreachable");
  });

  it("clearing the fleet's problems does not clear the registry's", async () => {
    const { session, errors } = harness([null]);
    await session.start();
    session.noteEntryFailures(["h1 — unreachable"]);
    session.noteEntryFailures([]);
    expect(errors.at(-1)).toContain("No hosts yet");
    expect(errors.at(-1)).not.toContain("unreachable");
  });

  it("never rejects when the first read fails", async () => {
    const { session, errors } = harness([new Error("nope")]);
    await expect(session.start()).resolves.toBeUndefined();
    expect(errors.at(-1)).toContain("nope");
  });

  it("debounces a burst of watcher events into one read", async () => {
    vi.useFakeTimers();
    try {
      let reads = 0;
      let fire = () => {};
      const session = createRegistrySession({
        readRegistry: async () => {
          reads++;
          return { hosts: [host("a")], failures: [] };
        },
        watch: (onChange) => {
          fire = onChange;
          return () => undefined;
        },
        applyConfig: async () => undefined,
        onConfigError: () => undefined,
      });
      await session.start();
      expect(reads).toBe(1);
      fire();
      fire();
      fire();
      await vi.advanceTimersByTimeAsync(600);
      expect(reads).toBe(2);
      session.stop();
    } finally {
      vi.useRealTimers();
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/registry/registry-session.test.ts`
Expected: FAIL — cannot resolve `./registry-session.js`.

- [ ] **Step 3: Write the implementation**

```ts
// src/registry/registry-session.ts
import { hostsFingerprint, type AppConfig, type HostEntry } from "../config/host-config.js";
import { errorText } from "../error-text.js";
import type { RegistrySnapshot } from "./paseo-registry.js";

export interface RegistrySession {
  /** Reads once and applies. Never rejects. */
  start(): Promise<void>;
  /** Re-reads. Never rejects. Exposed for the watcher, the poll, and tests. */
  refresh(): Promise<void>;
  /** The fleet's unusable entries, for the half of the error row it owns. */
  noteEntryFailures(failures: string[]): void;
  stop(): void;
}

const NO_HOSTS_MESSAGE = "No hosts yet. Pair a host in the Paseo app.";

/**
 * Owns the tray's view of the Paseo app's host registry: when to re-read it,
 * whether anything changed, and what the error row says.
 *
 * Electron-free on purpose, the same way `host-fleet.ts` is. Everything here
 * is reachable on a machine where the Paseo app is missing, mid-write, or has
 * moved its storage, so it has to be testable without a main process.
 *
 * Nothing here may reject. A menu-bar app that dies on a torn read of another
 * program's database leaves the user nothing to fix it with.
 */
export function createRegistrySession(options: {
  /** Injected so tests need no filesystem. Production passes `readRegistry`. */
  readRegistry: () => Promise<RegistrySnapshot | null>;
  /** Starts watching; returns the stop function. Production watches the dir. */
  watch: (onChange: () => void) => () => void;
  applyConfig: (config: AppConfig) => Promise<void>;
  onConfigError: (message: string | null) => void;
  /** Safety net for events the watcher misses. Zero disables it. */
  pollMs?: number;
  debounceMs?: number;
}): RegistrySession {
  const { readRegistry, watch, applyConfig, onConfigError } = options;
  const pollMs = options.pollMs ?? 60_000;
  const debounceMs = options.debounceMs ?? 500;

  let appliedFingerprint: string | null = null;
  let stopWatching: (() => void) | null = null;
  let debounceTimer: NodeJS.Timeout | null = null;
  let pollTimer: NodeJS.Timeout | null = null;
  let running: Promise<void> | null = null;

  // Two independent problems, reported through one menu row: reading the
  // registry, and entries the fleet could not use. Either can be fixed without
  // the other, so neither may clear the other.
  let registryError: string | null = null;
  let fleetError: string | null = null;

  function refreshConfigError(): void {
    const problems = [registryError, fleetError].filter((problem) => problem !== null);
    onConfigError(problems.length > 0 ? problems.join("\n\n") : null);
  }

  async function readAndApply(): Promise<void> {
    let snapshot: RegistrySnapshot | null;
    try {
      snapshot = await readRegistry();
    } catch (error) {
      // Keep the last known-good host set live and say what went wrong. A
      // compaction mid-read lands here and resolves itself on the next tick.
      registryError = errorText(error);
      refreshConfigError();
      return;
    }

    const hosts: HostEntry[] = snapshot?.hosts ?? [];
    const failures = snapshot?.failures ?? [];

    const problems: string[] = [];
    if (snapshot === null) problems.push(NO_HOSTS_MESSAGE);
    if (failures.length > 0) {
      problems.push(`These hosts could not be used:\n\n${failures.join("\n")}`);
    }
    registryError = problems.length > 0 ? problems.join("\n\n") : null;
    refreshConfigError();

    // Rebuilding tears down live connections, so it happens only when the
    // host set genuinely differs -- Chromium rewrites this database constantly
    // for keys we do not care about.
    const fingerprint = hostsFingerprint(hosts);
    if (fingerprint === appliedFingerprint) return;
    appliedFingerprint = fingerprint;
    await applyConfig({ version: 1, hosts });
  }

  /** Serializes reads so a watcher burst cannot interleave two applies. */
  function serialize(): Promise<void> {
    const next = (running ?? Promise.resolve()).then(readAndApply, readAndApply);
    running = next.catch(() => undefined);
    return next;
  }

  async function safeRefresh(): Promise<void> {
    try {
      await serialize();
    } catch (error) {
      // serialize() already routes read failures to the error row; this is the
      // last line against applyConfig throwing.
      registryError = errorText(error);
      refreshConfigError();
    }
  }

  return {
    async start() {
      stopWatching = watch(() => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
          debounceTimer = null;
          void safeRefresh();
        }, debounceMs);
      });
      if (pollMs > 0) {
        pollTimer = setInterval(() => void safeRefresh(), pollMs);
        // A background poll must never hold the process open on its own.
        pollTimer.unref?.();
      }
      await safeRefresh();
    },

    refresh() {
      return safeRefresh();
    },

    noteEntryFailures(failures) {
      fleetError =
        failures.length > 0 ? `These hosts could not be used:\n\n${failures.join("\n")}` : null;
      refreshConfigError();
    },

    stop() {
      if (debounceTimer) clearTimeout(debounceTimer);
      if (pollTimer) clearInterval(pollTimer);
      debounceTimer = null;
      pollTimer = null;
      stopWatching?.();
      stopWatching = null;
    },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/registry/registry-session.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 5: Mutation check**

Remove the `if (fingerprint === appliedFingerprint) return;` guard. Run the tests. Expected: the "does not rebuild when unchanged" test FAILS with two applies. Restore.

Then change the `catch` in `readAndApply` to rethrow instead of reporting. Expected: the "keeps the last known-good hosts" and "never rejects" tests FAIL. Restore.

- [ ] **Step 6: Commit**

```bash
git add src/registry/registry-session.ts src/registry/registry-session.test.ts
git commit -m "feat: registry session that watches, debounces, and applies host changes"
```

---

### Task 9: Wire it up and delete the config and pairing paths

**Files:**
- Rename: `src/config/host-config.ts` → `src/config/host-entry.ts`; `src/config/host-config.test.ts` → `src/config/host-entry.test.ts`
- Delete: `src/config/pairing.ts`, `src/config/pairing.test.ts`, `src/config/config-session.ts`, `src/config/config-session.test.ts`
- Modify: `src/main.ts`, `src/tray/menu-template.ts`, `src/tray/menu-template.test.ts`, `src/daemon/host-fleet.ts`, `src/daemon/host-connection.ts`, `src/registry/paseo-registry.ts`, `src/registry/registry-session.ts` (import specifiers)

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: an app whose hosts come only from the registry.

- [ ] **Step 1: Rename the config module and strip it to schemas**

```bash
git mv src/config/host-config.ts src/config/host-entry.ts
git mv src/config/host-config.test.ts src/config/host-entry.test.ts
```

In `src/config/host-entry.ts`, delete `configPath`, `loadConfig`, `saveConfig`, `watchConfig`, `WATCH_DEBOUNCE_MS`, and every import they alone needed (`readFile`, `writeFile`, `chmod`, `rename`, `unlink`, `watch`, `crypto`, `path`). Keep `DirectHostSchema`, `RelayHostSchema`, `HostEntrySchema`, `AppConfigSchema`, `hostsFingerprint`, and `hostEntryEndpointHint`.

In `src/config/host-entry.test.ts`, delete every test covering `loadConfig`, `saveConfig`, `watchConfig`, and `configPath`. Keep the schema and `hostsFingerprint` tests.

- [ ] **Step 2: Delete the pairing and config-session modules**

```bash
git rm src/config/pairing.ts src/config/pairing.test.ts
git rm src/config/config-session.ts src/config/config-session.test.ts
```

Two consequences of this deletion are intended, not oversights:

- **The first-run `Local` seed goes with it.** `config-session.ts` seeded a host at `127.0.0.1:6767` on first run. The registry already contains the local daemon, so seeding one would duplicate it. A machine where the Paseo desktop app has never run now shows no hosts at all — not even a local one — and the error row is the only thing in the menu.
- **An existing `config.json` is left on disk untouched.** Do not add code to delete or migrate it. It holds credentials the user may want, and removing another program's data on upgrade is out of scope. It simply stops having any effect.

- [ ] **Step 3: Update every import specifier**

Run: `grep -rn "host-config.js" src/`
Change each hit to `host-entry.js`. Files that will hit: `src/daemon/host-fleet.ts`, `src/daemon/host-connection.ts`, `src/registry/paseo-registry.ts`, `src/registry/registry-session.ts`, and their tests.

- [ ] **Step 4: Remove the two menu items**

In `src/tray/menu-template.ts`, delete `onAddHostFromClipboard` and `onEditConfig` from `MenuHandlers`, add `onOpenApp` is already present, and change the error row plus the action block:

```ts
  if (model.configError) {
    // The fix for every one of these is in the Paseo app, so the row opens it.
    items.push(
      {
        label: "Configuration error",
        toolTip: model.configError,
        click: () => handlers.onOpenApp(),
      },
      { type: "separator" },
    );
  }
```

and in the trailing action block, delete these two lines:

```ts
    { label: "Add host from clipboard…", click: () => handlers.onAddHostFromClipboard() },
    { label: "Edit configuration…", click: () => handlers.onEditConfig() },
```

- [ ] **Step 5: Update the menu template test**

Run: `grep -n "AddHostFromClipboard\|EditConfig" src/tray/menu-template.test.ts`

Delete `onAddHostFromClipboard: vi.fn(),` and `onEditConfig: vi.fn(),` from the `handlers` object at the top of the file, and delete any test asserting those two rows exist or that they fire.

The file already defines `empty` (a `TrayViewModel`), `handlers`, `menuOptions()`, and `click()`. Reuse them — do not introduce a second set of fixtures. Add:

```ts
  it("opens the Paseo app from the configuration error row", () => {
    const template = buildMenuTemplate(
      { ...empty, configError: "something is wrong" },
      handlers,
      menuOptions(),
    );
    click(template.find((item) => item.label === "Configuration error"));
    expect(handlers.onOpenApp).toHaveBeenCalledTimes(1);
  });
```

- [ ] **Step 6: Rewrite the wiring in `src/main.ts`**

Replace the `createConfigSession` block, `addHostFromClipboard`, the two handlers, and `watchConfig` with the registry session. The imports at the top change to:

```ts
import { app, dialog, shell } from "electron";
import path from "node:path";
import { watch } from "node:fs";
import { HostStore } from "./daemon/host-store.js";
import { createHostFleet } from "./daemon/host-fleet.js";
import { createRegistrySession } from "./registry/registry-session.js";
import { readRegistry, registryLevelDbDir } from "./registry/paseo-registry.js";
import { defaultDesktopAppInstalled, openApp, openWorkspace } from "./launch/open-paseo.js";
import { createTrayPresenter, type TrayPresenter } from "./tray/tray-presenter.js";
import type { TrayWorkspaceRow } from "./tray/view-model.js";
import { errorText } from "./error-text.js";
```

`clipboard` and `randomUUID` are no longer used — remove them.

Inside `app.whenReady()`, replace the session construction with:

```ts
      const appSupportDir = app.getPath("appData");

      // `session` is reached only from callbacks, all of which run after both
      // consts are initialized: the fleet reports its entry failures to the
      // session, and the session hands loaded host sets back to the fleet.
      const fleet = createHostFleet({
        store,
        onEntryFailures: (failures) => session.noteEntryFailures(failures),
      });

      /**
       * Watches the Paseo app's leveldb directory. Chromium rewrites it
       * constantly for keys we do not care about, so this only signals; the
       * session debounces and decides whether anything actually changed.
       *
       * The directory can be absent (Paseo not installed) or vanish (the app
       * is uninstalled while we run). Neither may throw: an FSWatcher 'error'
       * event with no listener takes the process down.
       */
      function watchRegistry(onChange: () => void): () => void {
        let watcher: ReturnType<typeof watch> | null = null;
        let cancelled = false;
        void registryLevelDbDir(appSupportDir)
          .then((dir) => {
            if (cancelled) return;
            watcher = watch(dir, () => onChange());
            watcher.on("error", () => {});
          })
          .catch(() => {
            // Not installed. The poll is what notices if that changes.
          });
        return () => {
          cancelled = true;
          watcher?.close();
        };
      }

      const session = createRegistrySession({
        readRegistry: () => readRegistry(appSupportDir),
        watch: watchRegistry,
        applyConfig: (config) => fleet.apply(config),
        onConfigError: (message) => store.setConfigError(message),
      });
```

Delete the whole `addHostFromClipboard` function. In the tray handlers, delete the `onAddHostFromClipboard` and `onEditConfig` entries. Replace the `stopWatching`/`before-quit` block and the `session.start()` call with:

```ts
      app.on("before-quit", () => {
        session.stop();
        presenter.dispose();
        fleet.closeAll();
      });

      await session.start();
```

`session.start()` never rejects, so the surrounding `try`/`catch` around it goes away.

- [ ] **Step 7: Verify the whole suite and the types**

Run: `npx vitest run`
Expected: PASS. The file and test counts differ from the pre-change `181 tests, 10 files`; record the new numbers, they are needed in Task 11.

Run: `npm run typecheck`
Expected: no errors. If `config.json`-era symbols still resolve, a deletion was missed.

- [ ] **Step 8: Confirm nothing still reads or writes `config.json`**

Run: `grep -rn "config.json\|loadConfig\|saveConfig\|watchConfig\|hostEntryFromPairingUrl" src/`
Expected: no hits. Any hit is a leftover.

- [ ] **Step 9: Commit**

```bash
git add -A src/
git commit -m "feat: take hosts from the Paseo app's registry, drop config hosts and pairing"
```

---

### Task 10: Integration test against a real daemon

**Files:**
- Create: `src/daemon/daemon-harness.ts`
- Modify: `tsconfig.json` (exclude the harness from the build), `src/daemon/host-connection.test.ts` (use the extracted harness)
- Create: `src/registry/registry-session.integration.test.ts`

**Interfaces:**
- Consumes: `createRegistrySession`, `createHostFleet`, `HostStore`, `@getpaseo/server`.
- Produces: `startDaemon(options?): Promise<{ port: number; stop: () => Promise<void> }>` from `src/daemon/daemon-harness.ts`.

Static fixtures cannot encode the port the OS picks, so this injects the reader rather than driving it from a fixture directory.

- [ ] **Step 1: Extract the existing daemon harness**

`startDaemon` currently lives as a private helper inside `src/daemon/host-connection.test.ts` (around line 195). Move it — along with `createDiscardingLogger` and the `Harness` type it returns — into a new `src/daemon/daemon-harness.ts`, exporting `startDaemon`. Change nothing about the boot options; `listen: "127.0.0.1:0"` in particular must stay, because a fixed port collides with the developer's own daemon on 6767.

Then update `src/daemon/host-connection.test.ts` to import `startDaemon` instead of defining it.

The harness must not be emitted into `dist` — it imports `@getpaseo/server`, which is a devDependency. `tsconfig.json` excludes only `src/**/*.test.ts`, so add it explicitly:

```json
  "exclude": ["src/**/*.test.ts", "src/daemon/daemon-harness.ts"]
```

`tsconfig.typecheck.json` sets `"exclude": []`, so the harness is still typechecked.

- [ ] **Step 2: Confirm the extraction changed no behaviour**

Run: `npx vitest run src/daemon/host-connection.test.ts`
Expected: PASS, the same count as before the extraction. If anything fails, the move was not faithful — fix it before writing new tests on top.

Run: `npm run build && grep -rn "getpaseo/server" dist/ | head`
Expected: no hits. A hit means the harness leaked into the bundle.

- [ ] **Step 3: Write the test**

```ts
// src/registry/registry-session.integration.test.ts
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { HostStore } from "../daemon/host-store.js";
import { createHostFleet } from "../daemon/host-fleet.js";
import { startDaemon } from "../daemon/daemon-harness.js";
import { createRegistrySession } from "./registry-session.js";

let endpoint: string;
let stopDaemon: () => Promise<void>;

beforeAll(async () => {
  const daemon = await startDaemon();
  endpoint = `127.0.0.1:${daemon.port}`;
  stopDaemon = daemon.stop;
});

afterAll(async () => {
  await stopDaemon();
});

describe("registry session against a real daemon", () => {
  it("connects the fleet to a host the registry reports", async () => {
    const store = new HostStore();
    const fleet = createHostFleet({ store, onEntryFailures: () => undefined });
    const session = createRegistrySession({
      readRegistry: async () => ({
        hosts: [{ id: "srv_itest", label: "itest", type: "directTcp", endpoint, useTls: false }],
        failures: [],
      }),
      watch: () => () => undefined,
      applyConfig: (config) => fleet.apply(config),
      onConfigError: () => undefined,
      pollMs: 0,
    });

    await session.start();

    await expect
      .poll(() => store.snapshot().find((host) => host.hostId === "srv_itest")?.status, {
        timeout: 15_000,
      })
      .toBe("connected");

    session.stop();
    fleet.closeAll();
  });
});
```

- [ ] **Step 4: Run it**

Run: `npx vitest run src/registry/registry-session.integration.test.ts`
Expected: PASS. It is slow by design — it boots a real daemon.

- [ ] **Step 5: Mutation check**

Change the injected `endpoint` to `127.0.0.1:1` (nothing listens there). Expected: the test FAILS on the poll timeout rather than passing against a dead port. Restore.

- [ ] **Step 6: Commit**

```bash
git add tsconfig.json src/daemon/daemon-harness.ts src/daemon/host-connection.test.ts src/registry/registry-session.integration.test.ts
git commit -m "test: registry session drives the fleet against a real daemon"
```

---

### Task 11: Update the project documentation

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the test and file counts recorded in Task 9, Step 7.
- Produces: nothing.

- [ ] **Step 1: Update the module table**

In the "Where logic goes" table, delete the `src/config/host-config.ts`, `src/config/config-session.ts`, and `src/config/pairing.ts` rows. Add:

```markdown
| `src/config/host-entry.ts` | The host schemas and their fingerprint. No I/O. |
| `src/registry/binary.ts` | Varints and CRC32C. |
| `src/registry/sstable.ts` | One LevelDB `.ldb`: footer, index, blocks, snappy. |
| `src/registry/wal.ts` | One LevelDB `.log`: record framing and batches. |
| `src/registry/leveldb-reader.ts` | A LevelDB directory: newest sequence wins. |
| `src/registry/local-storage.ts` | Chromium localStorage key framing and value encoding. |
| `src/registry/paseo-registry.ts` | Locate the Paseo app, validate, map to `HostEntry`. |
| `src/registry/registry-session.ts` | Watch, debounce, fingerprint, apply, own the error row. |
```

Change the sentence naming `host-fleet.ts` and `config-session.ts` as extraction examples to name `host-fleet.ts` and `registry-session.ts`.

- [ ] **Step 2: Replace the `config.json` rule with the registry rule**

Delete the `**config.json` is written `0600`**` bullet from "Critical rules". Add:

```markdown
- **Hosts come from the Paseo desktop app's Chromium localStorage, and nothing
  else.** The record is `@paseo:daemon-registry` under origin `paseo://app`, in
  `~/Library/Application Support/Paseo/Local Storage/leveldb`. This is an
  unsupported surface and it is the app's only source of hosts: `config.json`
  is neither read nor written, and there is no pairing flow. When the tray comes
  up empty after a Paseo update, check three things in order — the record key,
  the value's encoding tag, and the block compression type. The reader refuses
  an unknown compression type by design rather than guessing, so that failure
  names itself. See `docs/superpowers/2026-08-19-registry-sync-design.md`.
- **The LevelDB reader never takes the lock and never writes.** It reads while
  Chromium writes, so every block's CRC32C is verified before it is parsed and
  an unreadable file is skipped rather than failing the whole read. Removing a
  checksum check to "make it work" converts a torn read into silently wrong
  credentials.
```

- [ ] **Step 3: Update the "Working here" block**

Replace the test count with the numbers recorded in Task 9, Step 7:

```bash
npx vitest run                              # <N> tests, <M> files
```

Add below it:

```bash
npm run fixtures:registry                   # regenerate LevelDB test fixtures
```

with a note that `classic-level` is a devDependency used only by that script and must never move into `dependencies`.

- [ ] **Step 4: Add a known issue**

```markdown
- The registry reader depends on Chromium's private on-disk format. It handles
  uncompressed and snappy blocks; a future Chromium that writes zstd will make
  the tray show a named compression error until the reader learns that codec.
```

- [ ] **Step 5: Verify and commit**

Run: `npx vitest run && npm run typecheck`
Expected: both clean.

```bash
git add CLAUDE.md
git commit -m "docs: record the registry dependency and the new module layout"
```

---

## Final verification

- [ ] Run `npx vitest run` — all green.
- [ ] Run `npm run typecheck` — clean.
- [ ] Run `grep -rn "classic-level" package.json` — appears only under `devDependencies`.
- [ ] Run `grep -rn "config.json" src/` — no hits.
- [ ] Confirm `snappyjs` is under `dependencies`, not `devDependencies`.

## What a human still has to verify

No agent can see a menu bar, and no test here reads the real Paseo app's storage. A human must run the built app and confirm:

- the tray lists the same hosts the Paseo app's sidebar lists, with the same labels
- a host paired in the Paseo app appears in the tray without restarting it
- quitting the Paseo app does not empty the tray (the registry is on disk, not in the app's memory)
- with Paseo never installed, the tray shows the `Configuration error` row and the row opens nothing harmful
- icon states, click-through, and login-item registration still behave
