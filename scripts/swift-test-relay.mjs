// The full relay path for the opt-in Swift end-to-end test: a local relay
// under `wrangler dev`, then a real `@getpaseo/server` 0.4.0 daemon registered
// with it. Prints one JSON line when both are up:
//
//   {"relayEndpoint":"127.0.0.1:N","serverId":"…","daemonPublicKeyB64":"…"}
//
// and tears both down when stdin closes. Needs `scripts/relay-harness`
// installed first: `npm install --prefix scripts/relay-harness`.
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";

const harnessDir = fileURLToPath(new URL("./relay-harness/", import.meta.url));
// wrangler's package exports do not expose its bin script to `require.resolve`,
// so the path is built by hand and checked.
const wranglerCli = path.join(harnessDir, "node_modules", "wrangler", "bin", "wrangler.js");
if (!existsSync(wranglerCli)) {
  process.stderr.write("scripts/relay-harness is not installed; run: npm install --prefix scripts/relay-harness\n");
  process.exit(2);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitForHealth(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`relay did not answer ${url} within ${timeoutMs}ms`);
}

let stopping = false;
const relayPort = await freePort();
const relay = spawn(
  process.execPath,
  [wranglerCli, "dev", "--local", "--ip", "127.0.0.1", "--port", String(relayPort), "--live-reload=false", "--show-interactive-dev-session=false"],
  { cwd: harnessDir, stdio: ["ignore", "pipe", "pipe"] },
);
relay.stdout.on("data", (chunk) => process.stderr.write(chunk));
relay.stderr.on("data", (chunk) => process.stderr.write(chunk));
relay.on("exit", (code) => {
  if (!stopping) {
    process.stderr.write(`relay exited early with code ${code}\n`);
    process.exit(1);
  }
});
// Node does not kill its children on exit, and `stop()` below is only reachable
// once stdin closes. Every failure path before that -- the health check timing
// out, the daemon boot throwing -- used to leave `wrangler dev` running and
// holding this port until someone noticed.
process.on("exit", () => {
  if (!stopping) relay.kill("SIGKILL");
});

try {
  await waitForHealth(`http://127.0.0.1:${relayPort}/health`, 90_000);
} catch (error) {
  stopping = true;
  relay.kill("SIGKILL");
  throw error;
}

const logger = pino({ level: "warn" }, new Writable({ write(_chunk, _encoding, callback) { callback(); } }));
const root = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-swift-relay-"));
const paseoHome = path.join(root, ".paseo");
await mkdir(paseoHome, { recursive: true });
const staticDir = await mkdtemp(path.join(os.tmpdir(), "paseo-menubar-swift-relay-static-"));
const relayEndpoint = `127.0.0.1:${relayPort}`;

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
    relayEnabled: true,
    relayEndpoint,
    relayUseTls: false,
    appBaseUrl: "https://app.paseo.sh",
  },
  logger,
);
await daemon.start();

const serverId = (await readFile(path.join(paseoHome, "server-id"), "utf8")).trim();
const { publicKeyB64 } = JSON.parse(await readFile(path.join(paseoHome, "daemon-keypair.json"), "utf8"));
process.stdout.write(JSON.stringify({ relayEndpoint, serverId, daemonPublicKeyB64: publicKeyB64 }) + "\n");

async function stop() {
  stopping = true;
  await daemon.stop().catch(() => undefined);
  relay.kill("SIGTERM");
  await rm(root, { recursive: true, force: true });
  await rm(staticDir, { recursive: true, force: true });
  process.exit(0);
}

process.stdin.on("end", () => { void stop(); });
process.stdin.resume();
