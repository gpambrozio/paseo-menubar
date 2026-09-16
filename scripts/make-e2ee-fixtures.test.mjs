import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import nacl from "tweetnacl";
import { describe, expect, it } from "vitest";

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "make-e2ee-fixtures.mjs");
const committed = path.join(here, "..", "PaseoIconPackage", "Tests", "PaseoIconCoreTests", "Fixtures", "e2ee-vectors.json");
const bytes = (base64) => new Uint8Array(Buffer.from(base64, "base64"));

/** Every vector must open with tweetnacl from the daemon's side of the exchange. */
function expectDecryptable(fixture) {
  for (const vector of fixture.vectors) {
    const shared = nacl.box.before(bytes(vector.clientPublicKeyB64), bytes(vector.daemonSecretKeyB64));
    expect(Buffer.from(shared).toString("base64"), vector.name).toBe(vector.sharedKeyB64);
    const bundle = bytes(vector.bundleB64);
    const opened = nacl.box.open.after(bundle.subarray(24), bundle.subarray(0, 24), shared);
    expect(opened, vector.name).not.toBeNull();
    expect(Buffer.from(opened).toString("base64"), vector.name).toBe(vector.plaintextB64);
  }
}

describe("make-e2ee-fixtures", () => {
  it("the committed fixture is what tweetnacl produces", () => {
    const fixture = JSON.parse(readFileSync(committed, "utf8"));
    expect(fixture.vectors.map((vector) => vector.name)).toEqual([
      "empty", "one-byte", "hello-json", "session-envelope", "large-text", "binary",
    ]);
    expect(bytes(fixture.lowOrderPublicKeyB64)).toEqual(new Uint8Array(32));
    expectDecryptable(fixture);
  });

  it("regenerates a fixture of the same shape", () => {
    const target = path.join(mkdtempSync(path.join(os.tmpdir(), "e2ee-fixtures-")), "vectors.json");
    execFileSync(process.execPath, [script, target]);
    expectDecryptable(JSON.parse(readFileSync(target, "utf8")));
  });
});
