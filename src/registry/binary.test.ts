import { describe, expect, it } from "vitest";
import { crc32c, maskCrc, readVarint32, readVarint64, unmaskCrc } from "./binary.js";

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
    expect(unmaskCrc(maskCrc(crc))).toBe(crc);
  });

  it("masks the way LevelDB does, not merely in a way unmaskCrc undoes", () => {
    // LevelDB: ((crc >> 15) | (crc << 17)) + 0xa282ead8. Pinned as an
    // independent expression so a matching mistake in both directions
    // cannot pass the round-trip above.
    const crc = 0x12345678;
    expect(maskCrc(crc)).toBe((((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0);
  });
});
