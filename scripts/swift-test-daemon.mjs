// Boots a real `@getpaseo/server` 0.4.0 daemon on an OS-assigned port for the
// Swift integration tests, in the shape the native app parity plan sets out.
// Prints one JSON line when ready:
//
//   {"port":N,"serverId":"…","daemonPublicKeyB64":"…"}
//
// and stops the daemon when stdin closes.
//
//   node scripts/swift-test-daemon.mjs [--password <password>]
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Writable } from "node:stream";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";

const args = process.argv.slice(2);
const passwordIndex = args.indexOf("--password");
const password = passwordIndex === -1 ? undefined : args[passwordIndex + 1];

// The daemon logs a page of provider-reconciliation warnings on boot; they go
// nowhere so the Swift test output stays readable.
const logger = pino({ level: "warn" }, new Writable({ write(_chunk, _encoding, callback) { callback(); } }));

const root = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-swift-daemon-"));
const paseoHome = path.join(root, ".paseo");
await mkdir(paseoHome, { recursive: true });
const staticDir = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-swift-static-"));

const daemon = await createPaseoDaemon(
  {
    listen: "127.0.0.1:0",
    paseoHome,
    corsAllowedOrigins: [],
    hostnames: true,
    mcpEnabled: false,
    staticDir,
    mcpDebug: false,
    agentClients: {},
    agentStoragePath: path.join(paseoHome, "agents"),
    relayEnabled: false,
    relayEndpoint: "relay.paseo.sh:443",
    appBaseUrl: "https://app.paseo.sh",
    ...(password ? { auth: { password } } : {}),
  },
  logger,
);

await daemon.start();
const target = daemon.getListenTarget();
if (!target || target.type !== "tcp") throw new Error("expected a TCP listener");

// Both files are written by the daemon on first start: `server-id` is the
// relay session id and `daemon-keypair.json` holds the E2EE public key.
const serverId = (await readFile(path.join(paseoHome, "server-id"), "utf8")).trim();
const { publicKeyB64 } = JSON.parse(await readFile(path.join(paseoHome, "daemon-keypair.json"), "utf8"));

process.stdout.write(JSON.stringify({ port: target.port, serverId, daemonPublicKeyB64: publicKeyB64 }) + "\n");

async function stop() {
  await daemon.stop().catch(() => undefined);
  await rm(root, { recursive: true, force: true });
  await rm(staticDir, { recursive: true, force: true });
  process.exit(0);
}

process.stdin.on("end", () => { void stop(); });
process.stdin.resume();
