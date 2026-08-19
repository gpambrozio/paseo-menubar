// Chromium frames a localStorage record as `_<origin>\x00\x01<key>`.
import { ClassicLevel } from "classic-level";
import { rm, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
