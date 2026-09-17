// A WebSocket echo server for the Swift transport tests. Prints one JSON line
// with its port, sends each new client a report of the handshake it saw,
// echoes every frame, and closes with 4401 "Incorrect password" when a client
// sends the text "close-me" (the daemon's auth-rejection close, verbatim).
// Exits when stdin closes.
import { WebSocketServer } from "ws";

const wss = new WebSocketServer({
  host: "127.0.0.1",
  port: 0,
  // Echo the first offered subprotocol back, as the daemon's
  // `selectWebSocketProtocol` does for `paseo.bearer.*`.
  handleProtocols: (protocols) => (protocols.size > 0 ? [...protocols][0] : false),
});

wss.on("listening", () => {
  process.stdout.write(JSON.stringify({ port: wss.address().port }) + "\n");
});

wss.on("connection", (ws, request) => {
  ws.send(JSON.stringify({
    kind: "handshake",
    protocol: ws.protocol,
    authorization: request.headers.authorization ?? null,
  }));
  ws.on("message", (data, isBinary) => {
    if (!isBinary && data.toString() === "close-me") {
      ws.close(4401, "Incorrect password");
      return;
    }
    ws.send(data, { binary: isBinary });
  });
});

process.stdin.on("end", () => {
  wss.close();
  process.exit(0);
});
process.stdin.resume();
