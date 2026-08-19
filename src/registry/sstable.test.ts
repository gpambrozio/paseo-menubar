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

// Mirrors scripts/make-registry-fixtures.mjs's fillerKey: "0-key-*" sorts
// before the real registry key, "z-key-*" sorts after it.
function fillerKey(side: "0" | "z", index: number): Buffer {
  return Buffer.concat([
    Buffer.from("_paseo://app", "latin1"),
    Buffer.from([0x00, 0x01]),
    Buffer.from(`${side}-key-${String(index).padStart(4, "0")}`, "latin1"),
  ]);
}

// Mirrors scripts/make-registry-fixtures.mjs's STRADDLE_KEY: written many
// times with large values before compaction, so its run of internal-key
// versions is split across two data blocks.
const STRADDLE_KEY = Buffer.concat([
  Buffer.from("_paseo://app", "latin1"),
  Buffer.from([0x00, 0x01]),
  Buffer.from("zz-straddle", "latin1"),
]);

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

  describe("against a table with more than one data block", () => {
    it("finds the registry key even though it is not in the first data block", async () => {
      const records = findInTable(await tableBytes("multi-block"), KEY);
      expect(records).toHaveLength(1);
      expect(records[0]!.isDeletion).toBe(false);
      expect(Buffer.from(records[0]!.value).subarray(1).toString("latin1")).toContain(
        "multi-block",
      );
    });

    it("returns nothing for a key the table does not hold", async () => {
      const records = findInTable(await tableBytes("multi-block"), Buffer.from("_nope", "latin1"));
      expect(records).toEqual([]);
    });

    it("finds a key from a later data block, exercising the index seek's skip branch", async () => {
      const bytes = await tableBytes("multi-block");
      // The last "z-key-*" filler entry sorts well after the registry key,
      // so a correct seek has to skip past several data blocks to reach it.
      const records = findInTable(bytes, fillerKey("z", 199));
      expect(records).toHaveLength(1);
      expect(Buffer.from(records[0]!.value).subarray(1).toString("latin1")).toContain(
        "multi-block filler value 199",
      );
    });

    it("finds every version of a key whose run of internal keys straddles a block boundary", async () => {
      const bytes = await tableBytes("multi-block");
      const records = findInTable(bytes, STRADDLE_KEY);
      // All 10 puts to this key survive compaction; a scan that stops as
      // soon as it sees an index separator equal to the target (instead of
      // only when it sees one strictly greater) would silently drop
      // whichever versions landed in the second block.
      expect(records).toHaveLength(10);
      for (const record of records) {
        expect(Buffer.from(record.value).subarray(1).toString("latin1")).toContain(
          "straddle version",
        );
      }
    });
  });
});
