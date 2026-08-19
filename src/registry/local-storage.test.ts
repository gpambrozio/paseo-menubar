import { describe, expect, it } from "vitest";
import { decodeLocalStorageValue, localStorageKey } from "./local-storage.js";

describe("localStorageKey", () => {
  it("frames the key the way Chromium stores it", () => {
    const key = localStorageKey("paseo://app", "@paseo:daemon-registry");
    // The separator is two control bytes, 0x00 0x01 -- not printable, so it
    // is spelled out rather than embedded in a string literal.
    expect(Buffer.from(key)).toEqual(
      Buffer.concat([
        Buffer.from("_paseo://app", "latin1"),
        Buffer.from([0x00, 0x01]),
        Buffer.from("@paseo:daemon-registry", "latin1"),
      ]),
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
