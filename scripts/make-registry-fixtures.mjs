// Chromium frames a localStorage record as `_<origin>\x00\x01<key>`.
import { ClassicLevel } from "classic-level";
import { rm, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Runtime artifacts LevelDB writes that carry no fixture content: LOCK is an
// flock placeholder, LOG is an operational log full of timestamps and thread
// pointers. Neither is read by any parser this fixture feeds, and committing
// them would make every regeneration produce a timestamp-only diff.
const RUNTIME_ARTIFACTS = ["LOCK", "LOG"];

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
  await Promise.all(
    RUNTIME_ARTIFACTS.map((file) => rm(path.join(dir, file), { force: true })),
  );
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

/**
 * A synthetic filler key that sorts strictly before or strictly after the
 * real registry key. `_paseo://app\x00\x01@paseo:...` has 0x40 ("@") as the
 * first byte after the 0x00 0x01 tag; "0" (0x30) sorts before it and "z"
 * (0x7a) sorts after it, so a run of "0-key-*" entries lands before the real
 * key and a run of "z-key-*" entries lands after it, deterministically.
 */
function fillerKey(side, index) {
  return Buffer.concat([
    Buffer.from("_paseo://app", "latin1"),
    Buffer.from([0x00, 0x01]),
    Buffer.from(`${side}-key-${String(index).padStart(4, "0")}`, "latin1"),
  ]);
}

function fillerValue(index) {
  return latin1Value(`multi-block filler value ${index}`.padEnd(120, "-"));
}

// A key written many times with sizably large values before the table is
// compacted. Internal keys sort by user key first, so every version of this
// one user key lands contiguously in the sorted stream; making the run large
// enough (well past the ~4KB default block size) forces the block writer to
// split it mid-run, so its versions land in two different data blocks. This
// is the one shape that can actually distinguish "stop at the first data
// block whose separator is >= the target" from "stop only once the
// separator is strictly greater": a same-key run that straddles a block
// boundary needs the scan to continue past an equal separator. Sorts after
// every "z-key-*" filler entry ("zz" > "z-").
const STRADDLE_KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("zz-straddle", "latin1"),
]);

function straddleValue(index) {
  return latin1Value(`straddle version ${index}`.padEnd(700, "*"));
}

// Many keys, compacted into more than one data block (LevelDB's default
// block size is 4KB), with the real registry key placed after a full block's
// worth of filler so a broken index seek would miss it. Deterministic: no
// clock or PRNG, indices are zero-padded so ordering is stable.
await build("multi-block", async (db) => {
  for (let i = 0; i < 200; i++) {
    await db.put(fillerKey("0", i), fillerValue(i));
  }
  await db.put(KEY, latin1Value(hosts("multi-block")));
  for (let i = 0; i < 200; i++) {
    await db.put(fillerKey("z", i), fillerValue(i));
  }
  for (let i = 0; i < 10; i++) {
    await db.put(STRADDLE_KEY, straddleValue(i));
  }
  await db.compactRange(Buffer.alloc(0), Buffer.from([0xff, 0xff, 0xff, 0xff]));
});
