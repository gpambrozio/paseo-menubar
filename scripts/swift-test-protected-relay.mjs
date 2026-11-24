// Official 0.17.3 daemon in an isolated temporary home, behind a minimal
// relay-v2 byte forwarder. The forwarder does no encryption or authentication:
// those must interoperate between the actual daemon and the Swift client.
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Writable } from "node:stream";
import { WebSocket, WebSocketServer } from "ws";
import pino from "pino";
import { createPaseoDaemon } from "@getpaseo/server";
import { hashDaemonPassword } from "@getpaseo/server/auth";

const password = "isolated-relay-test-password"; // Synthetic fixture only.
let leakedCredential = false;
let clientConnections = 0;
let control;
let ready;
const controlReady = new Promise((resolve) => { ready = resolve; });
const pairs = new Map();
const server = createServer((req, res) => {
  if (req.url === "/stats") {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ leakedCredential, clientConnections }));
  } else if (req.url === "/disconnect" && req.method === "POST") {
    for (const { client } of pairs.values()) client.close(1012, "Test reconnect");
    res.end("ok");
  } else {
    res.writeHead(404).end();
  }
});
const wss = new WebSocketServer({ server, perMessageDeflate: false });
const send = (socket, data, binary = false) => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(data, { binary });
};
wss.on("connection", (socket, request) => {
  socket.on("error", () => {});
  const url = new URL(request.url, "http://localhost");
  const role = url.searchParams.get("role");
  const connectionId = url.searchParams.get("connectionId");
  if (role === "server" && !connectionId) {
    control = socket;
    send(control, JSON.stringify({ type: "sync", connectionIds: [...pairs.keys()] }));
    ready();
    return;
  }
  if (role === "client") {
    clientConnections++;
    if (JSON.stringify(request.headers).includes(password) || request.headers.authorization ||
        request.headers["sec-websocket-protocol"]?.includes("paseo-bearer") ||
        request.url.includes(password)) leakedCredential = true;
    const id = connectionId || randomUUID();
    const pair = { client: socket, daemon: null, queued: [] };
    pairs.set(id, pair);
    socket.on("message", (data, binary) => {
      if (data.toString().includes(password)) leakedCredential = true;
      if (pair.daemon) send(pair.daemon, data, binary);
      else pair.queued.push([data, binary]);
    });
    socket.on("close", () => {
      pairs.delete(id);
      send(control, JSON.stringify({ type: "disconnected", connectionId: id }));
      pair.daemon?.close(1001, "Client disconnected");
    });
    send(control, JSON.stringify({ type: "connected", connectionId: id }));
  } else if (role === "server" && connectionId && pairs.has(connectionId)) {
    const pair = pairs.get(connectionId);
    pair.daemon = socket;
    socket.on("message", (data, binary) => send(pair.client, data, binary));
    // Like the deployed relay, do not expose upstream application close text.
    socket.on("close", () => pair.client.close(1012, "Upstream connection closed"));
    for (const [data, binary] of pair.queued) send(socket, data, binary);
    pair.queued = [];
  } else socket.close(1008, "Unknown route");
});

const root = await mkdtemp(path.join(os.tmpdir(), "paseo-icon-protected-test-"));
let daemon;
let stopping = false;
async function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  const deadline = setTimeout(() => process.exit(1), 8_000);
  deadline.unref();
  await daemon?.stop().catch(() => {});
  for (const socket of wss.clients) socket.terminate();
  wss.close();
  server.close();
  await rm(root, { recursive: true, force: true });
  process.exit(code);
}
process.stdin.on("end", () => { void stop(); });
process.stdin.resume();
process.once("SIGTERM", () => { void stop(); });
try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const relayEndpoint = `127.0.0.1:${server.address().port}`;
  const paseoHome = path.join(root, ".paseo");
  const staticDir = path.join(root, "static");
  await mkdir(paseoHome);
  await mkdir(staticDir);
  const logger = pino({ level: "silent" }, new Writable({ write(_chunk, _encoding, callback) { callback(); } }));
  daemon = await createPaseoDaemon({
    listen: "127.0.0.1:0", paseoHome, staticDir, corsAllowedOrigins: [],
    hostnames: true, mcpEnabled: false, mcpDebug: false, usageEnabled: false,
    browserToolsEnabled: false, pluginsEnabled: false, resumeOnStartup: false,
    agentClients: {}, agentStoragePath: path.join(paseoHome, "agents"),
    relayEnabled: true, relayEndpoint, relayUseTls: false,
    relayRequireProtectedSecurity: true, auth: { password: hashDaemonPassword(password) },
  }, logger);
  await daemon.start();
  let timeout;
  await Promise.race([controlReady, new Promise((_, reject) => {
    timeout = setTimeout(() => reject(new Error("isolated relay startup timeout")), 15_000);
  })]).finally(() => clearTimeout(timeout));
  const serverId = (await readFile(path.join(paseoHome, "server-id"), "utf8")).trim();
  const { publicKeyB64 } = JSON.parse(await readFile(path.join(paseoHome, "daemon-keypair.json"), "utf8"));
  process.stdout.write(JSON.stringify({ relayEndpoint, serverId, daemonPublicKeyB64: publicKeyB64 }) + "\n");
} catch (error) {
  process.stderr.write(`Protected relay test harness: ${error.message}\n`);
  await stop(1);
}
