/**
 * Chromium's localStorage record layout, as stored in its LevelDB.
 *
 * Keys and values use the same string encoding: a leading tag byte, 0x01 for
 * Latin1 when every code unit fits in a byte and 0x00 for UTF-16LE otherwise,
 * followed by the bytes. Chromium picks per string, so both are reachable
 * from the same database and neither may be assumed.
 *
 * A record's key is `_<origin>` + 0x00 + the encoded key. The 0x00 is the
 * origin terminator; the byte after it is the key's own encoding tag, not a
 * second separator byte, which is why an ASCII key reads as 0x00 0x01.
 */

const LATIN1_TAG = 0x01;
const UTF16LE_TAG = 0x00;
const ORIGIN_TERMINATOR = 0x00;

function fitsLatin1(text: string): boolean {
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) > 0xff) return false;
  return true;
}

function encodeLocalStorageString(text: string): Buffer {
  const latin1 = fitsLatin1(text);
  return Buffer.concat([
    Buffer.from([latin1 ? LATIN1_TAG : UTF16LE_TAG]),
    Buffer.from(text, latin1 ? "latin1" : "utf16le"),
  ]);
}

export function localStorageKey(origin: string, key: string): Uint8Array {
  return new Uint8Array(
    Buffer.concat([
      Buffer.from(`_${origin}`, "latin1"),
      Buffer.from([ORIGIN_TERMINATOR]),
      encodeLocalStorageString(key),
    ]),
  );
}

export function decodeLocalStorageValue(value: Uint8Array): string {
  if (value.length === 0) throw new Error("localStorage value is empty");
  const tag = value[0]!;
  const body = Buffer.from(value.subarray(1));
  if (tag === LATIN1_TAG) return body.toString("latin1");
  if (tag === UTF16LE_TAG) return body.toString("utf16le");
  throw new Error(`Unknown localStorage value encoding tag ${tag}`);
}
