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
