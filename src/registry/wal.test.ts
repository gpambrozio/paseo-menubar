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
