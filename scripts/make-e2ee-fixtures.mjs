// Generates the E2EE interop vectors the Swift `E2EEBoxTests` decrypt and
// re-encrypt. tweetnacl is the reference implementation: `@getpaseo/relay`'s
// crypto.ts is a thin wrapper over it, so a Swift channel that matches these
// bytes matches the daemon. Regenerate with `npm run fixtures:e2ee`; the
// output is committed so the Swift tests need no Node at test time.
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import nacl from "tweetnacl";

const b64 = (bytes) => Buffer.from(bytes).toString("base64");

function vector(name, plaintextBytes, isBinary) {
  const daemon = nacl.box.keyPair();
  const client = nacl.box.keyPair();
  const shared = nacl.box.before(daemon.publicKey, client.secretKey);
  const nonce = nacl.randomBytes(nacl.box.nonceLength);
  const box = nacl.box.after(plaintextBytes, nonce, shared);
  const bundle = new Uint8Array(nonce.length + box.length);
  bundle.set(nonce, 0);
  bundle.set(box, nonce.length);
  return {
    name,
    isBinary,
    daemonPublicKeyB64: b64(daemon.publicKey),
    daemonSecretKeyB64: b64(daemon.secretKey),
    clientPublicKeyB64: b64(client.publicKey),
    clientSecretKeyB64: b64(client.secretKey),
    sharedKeyB64: b64(shared),
    nonceB64: b64(nonce),
    plaintextB64: b64(plaintextBytes),
    bundleB64: b64(bundle),
  };
}

const hello = JSON.stringify({
  type: "hello",
  clientId: "paseo-menubar-fixture",
  clientType: "cli",
  protocolVersion: 1,
  capabilities: { selective_agent_timeline: true },
  appVersion: "0.4.0",
});

const fixture = {
  // 32 zero bytes: a low-order point. tweetnacl's deriveSharedKey throws on it
  // and libsodium's crypto_box_beforenm refuses it; the Swift side must throw.
  lowOrderPublicKeyB64: b64(new Uint8Array(32)),
  vectors: [
    vector("empty", new Uint8Array(0), false),
    vector("one-byte", Buffer.from("x", "utf8"), false),
    vector("hello-json", Buffer.from(hello, "utf8"), false),
    vector("session-envelope", Buffer.from(JSON.stringify({ type: "session", message: { type: "ping", requestId: "r1" } }), "utf8"), false),
    vector("large-text", Buffer.from("a".repeat(4096), "utf8"), false),
    vector("binary", randomBytes(1024), true),
  ],
};

const target = process.argv[2];
if (!target) throw new Error("usage: make-e2ee-fixtures.mjs <output path>");
writeFileSync(target, JSON.stringify(fixture, null, 2) + "\n");
console.log(`wrote ${fixture.vectors.length} vectors to ${target}`);
