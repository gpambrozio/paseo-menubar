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
