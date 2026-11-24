// Run after installing the relay dev dependency:
//   node scripts/make-protected-relay-fixtures.mjs
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

// Use the published implementation, including internals behind its exports map.
// The installed version is recorded in the fixture to make regeneration auditable.
const e2ee = new URL(import.meta.resolve("@getpaseo/relay/e2ee"));
const { version } = JSON.parse(await readFile(new URL("../package.json", e2ee), "utf8"));
const { CipherState, createNoiseInitiator, createNoiseResponder } = await import(
  new URL("./noise/index.js", e2ee)
);
const { encodeProtectedRecord, MAX_CHUNK_DATA_BYTES } = await import(
  new URL("./protected-records.js", e2ee)
);
const { x25519 } = await import(
  pathToFileURL(createRequire(e2ee).resolve("@noble/curves/ed25519.js"))
);

function testKeyPair(start) {
  const secretKey = Uint8Array.from({ length: 32 }, (_, index) => start + index);
  return { secretKey, publicKey: x25519.getPublicKey(secretKey) };
}

const base64 = (bytes) => Buffer.from(bytes).toString("base64");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const prologue = Buffer.from("paseo-relay-e2ee/1");
const daemon = testKeyPair(1);
function handshake(offeredBinary, selectedParams) {
  const initiator = createNoiseInitiator({
    remoteStatic: daemon.publicKey,
    ephemeral: testKeyPair(33),
    prologue,
  });
  const responder = createNoiseResponder({
    localStatic: daemon,
    ephemeral: testKeyPair(65),
    prologue,
  });
  const hello = initiator.writeMessage(Uint8Array.of(1, Number(offeredBinary)));
  responder.readMessage(hello);
  const ready = responder.writeMessage(Uint8Array.from(selectedParams));
  initiator.readMessage(ready);
  return { hello: base64(hello), ready: base64(ready), client: initiator.split(), server: responder.split() };
}

const { hello, ready, client, server } = handshake(true, [1, 1]);
const clientText = "hello 世界 🌉";
const clientEmpty = encodeProtectedRecord("binary", Uint8Array.of(), client.send);
const clientTextWire = encodeProtectedRecord("text", Buffer.from(clientText), client.send);
const multichunk = Uint8Array.from(
  { length: MAX_CHUNK_DATA_BYTES + 17 },
  (_, index) => index % 251,
);
const clientMultichunk = encodeProtectedRecord("binary", multichunk, client.send);

const serverText = "ready ✓";
const serverTextWire = encodeProtectedRecord("text", Buffer.from(serverText), server.send);
const serverBinary = Uint8Array.of(0, 255, 42, 17);
const serverBinaryWire = encodeProtectedRecord("binary", serverBinary, server.send);
const serverEmptyWire = encodeProtectedRecord("text", Uint8Array.of(), server.send);

const fallback = handshake(true, [1, 0]);
const fallbackBinaryWire = encodeProtectedRecord("binary", serverBinary, fallback.client.send);
const invalidReady = [
  ["Unsupported protected parameter version", true, [2, 1]],
  ["Reserved protected parameter flag set", true, [1, 3]],
  ["Invalid protected parameter payload", true, [1]],
  ["Daemon selected an unoffered protected parameter", false, [1, 1]],
].map(([error, offeredBinary, selectedParams]) => ({
  error,
  offeredBinary,
  ready: handshake(offeredBinary, selectedParams).ready,
}));

const cipher = new CipherState();
const counterKey = testKeyPair(97).secretKey;
cipher.initializeKey(counterKey, 0x0102030405060708n);
const highCounterCiphertext = cipher.encryptWithAd(Uint8Array.of(), Uint8Array.of(1, 2, 3));

const fixture = {
  provenance: `@getpaseo/relay@${version} dist/noise/index.js and dist/protected-records.js`,
  staticPublicKey: base64(daemon.publicKey),
  clientEphemeral: base64(testKeyPair(33).secretKey),
  hello,
  ready,
  clientText,
  clientTextWire: base64(clientTextWire),
  clientEmptyWire: base64(clientEmpty),
  clientMultichunkBytes: multichunk.length,
  clientMultichunkWireBytes: clientMultichunk.length,
  clientMultichunkSHA256: sha256(clientMultichunk),
  serverText,
  serverTextWire: base64(serverTextWire),
  serverBinary: base64(serverBinary),
  serverBinaryWire: base64(serverBinaryWire),
  serverEmptyWire: base64(serverEmptyWire),
  readyWithoutBinary: fallback.ready,
  fallbackBinaryWire: base64(fallbackBinaryWire),
  invalidReady,
  counterKey: base64(counterKey),
  highCounterCiphertext: base64(highCounterCiphertext),
};
const output = new URL(
  "../PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/protected-relay-vectors.json",
  import.meta.url,
);
await writeFile(output, JSON.stringify(fixture, null, 2) + "\n");
