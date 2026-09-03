import { describe, expect, it } from "vitest";
import { decodeLocalStorageValue, localStorageKey } from "./local-storage.js";

describe("localStorageKey", () => {
  it("frames the key the way Chromium stores it", () => {
    const key = localStorageKey("paseo://app", "@paseo:daemon-registry");
    // 0x00 terminates the origin; 0x01 is the key's own Latin1 encoding tag,
    // the same tag a value carries. Neither is printable, so they are spelled
    // out rather than embedded in a string literal.
    expect(Buffer.from(key)).toEqual(
      Buffer.concat([
        Buffer.from("_paseo://app", "latin1"),
        Buffer.from([0x00, 0x01]),
        Buffer.from("@paseo:daemon-registry", "latin1"),
      ]),
    );
  });

  it("tags a key that does not fit in Latin1 as UTF-16LE, as Chromium does", () => {
    const key = localStorageKey("paseo://app", "☕");
    expect(Buffer.from(key)).toEqual(
      Buffer.concat([
        Buffer.from("_paseo://app", "latin1"),
        Buffer.from([0x00, 0x00]),
        Buffer.from("☕", "utf16le"),
      ]),
    );
  });
});

describe("decodeLocalStorageValue", () => {
  it("decodes a Latin1-tagged value", () => {
    const value = Buffer.concat([Buffer.from([0x01]), Buffer.from("hosts", "latin1")]);
    expect(decodeLocalStorageValue(value)).toBe("hosts");
  });

  it("preserves a non-ASCII byte through the Latin1 path", () => {
    // Chromium picks the Latin1 tag whenever every code unit is <= 0xFF, so a
    // host label with an accent in it lands here, not on the UTF-16 branch.
    // An ASCII-only assertion cannot tell this decode from a UTF-8 one: 0xE9
    // is `é` in Latin1 and an invalid lead byte in UTF-8, which is what makes
    // it the discriminating case.
    const value = Buffer.concat([Buffer.from([0x01]), Buffer.from("café", "latin1")]);
    expect(Buffer.from(value).at(-1)).toBe(0xe9);
    expect(decodeLocalStorageValue(value)).toBe("café");
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
