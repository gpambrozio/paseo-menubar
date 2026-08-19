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
