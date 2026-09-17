# Paseo Icon as a native macOS app

**Standing: binding** for the native build. The two existing binding documents
still define *what* the tray shows: `2026-08-16-standalone-menubar-app-design.md`
for rows, buckets, labels, click targets, and the no-derivation rule, and
`2026-08-19-registry-sync-design.md` for where hosts come from. This document
changes *how* it is built and adds the one thing the Electron build never had
to specify: the daemon wire contract, because a native app cannot use the
TypeScript SDK. Where this document and the implementation plans disagree,
this document wins.

## Why

The Electron `Tray` API is an image plus a title string. It cannot draw a
count badge, cannot color the item for attention, cannot host a popover, and
the design deferred a preferences window because it would have needed a
`BrowserWindow`. A native app gets all of that from AppKit and SwiftUI and
ships as a few megabytes instead of a bundled browser.

The user's main host is remote through a relay, so relay support with
end-to-end encryption is a v1 requirement, not a later phase.

## Decisions

### Language and UI toolkit

Swift, built as a Swift Package with a SwiftUI `App`. The menu bar item is
SwiftUI's `MenuBarExtra`. Its label is a SwiftUI view rendered to a
non-template `NSImage` through `ImageRenderer`, which is how the item gets a
colored icon and a count in one image. This is the pattern proven in the
user's own Gallager app
(`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MenuBarExtraView.swift`).

The style was `.menu` through plan 2 and is `.window` as of 2026-09-17, which
is phase 5 below. Menu style makes every row an `NSMenuItem`, and an
`NSMenuItem` drops the view modifiers around its title and draws a
non-clickable row in the disabled gray whatever color the attributed title
asks for. That is not a styling inconvenience: it means a section heading
cannot be made prominent, which is the first thing the menu was asked for
beyond parity. Window style makes every row a real SwiftUI view, at the cost
of owning what a menu gave for free — the hit area, the pointer highlight, the
scrolling, and closing the panel after a row is clicked. The panel is still not
a window in the sense the standalone design forbids: it belongs to the menu bar
item and closes when it resigns key. `MenuModel` is untouched by the change,
which is the point of keeping the menu as data — 349 tests still describe every
row. What it does cost is keyboard navigation: arrow keys, type-select and the
menu's VoiceOver semantics came with `NSMenu` and do not come with a panel. That
is a regression, recorded in `CLAUDE.md`'s known issues rather than discovered
later.

AppKit's `NSStatusItem` is not used unless a need appears that `MenuBarExtra`
cannot meet: a live animated status view, distinguishing left from right
click, or a popover positioned by hand. None is in scope.

The deployment floor is macOS 14. `MenuBarExtra` and `ImageRenderer` need 13;
the Observation framework needs 14. This raises the floor from the Electron
build's 13, and the cask's `depends_on macos` line changes with the first
native release.

### Behaviour is unchanged

Same rows, same five state buckets, same labels, same click targets, same
registry source, same error rows, same login item. `WorkspaceDescriptor.status`
is rendered, never derived. Section order and labels are still copied from
upstream's `sidebar-status-view-model.ts`. One bad profile still never costs
another host. Every rule in the two earlier design documents carries over.

### No SDK: the wire contract is the pin

There is no Swift client upstream. The native app speaks the daemon protocol
directly and is pinned to `protocolVersion: 1` and the message shapes of
`@getpaseo/protocol` 0.4.0, which is the version the Electron build pins. The
protocol contract upstream is additive-only (`docs/protocol-compatibility.md`
in the Paseo repo), so a client that ignores unknown fields and treats unknown
enum values as visible unknowns stays compatible with newer daemons for the
same reason the pinned SDK did.

Decoding rules that follow from that:

- Unknown fields are ignored. Codable does this by default.
- Enum-like strings (`status` on workspaces and agents) are kept as strings.
  A bucket this build does not know renders as an unknown row, never as a
  crash and never as a guess.
- Only the messages below are parsed. Everything else is `other` and dropped.

The slice of the protocol the tray speaks:

| Direction | Message | Purpose |
| --- | --- | --- |
| out | `hello` | Identify: `clientId`, `clientType: "cli"`, `protocolVersion: 1`, `appVersion`, capabilities |
| in | `session` / `status` with `status: "server_info"` | `serverId` and `hostname`; marks the session connected |
| out | `session` / `fetch_agents_request` | Seed agents, sorted `status_priority asc, updated_at desc`, page 200, `subscribe: {}` |
| out | `session` / `fetch_workspaces_request` | Seed workspaces, sorted `status_priority asc`, page 200, `subscribe: {}` |
| in | `session` / `fetch_*_response` | Correlated by `payload.requestId`; carries `entries` and `pageInfo.hasMore` |
| in | `session` / `rpc_error` | Fails the request named by `payload.requestId` |
| in | `session` / `agent_update` | `upsert` with `agent`, or `remove` with `agentId` |
| in | `session` / `workspace_update` | `upsert` with `workspace`, or `remove` with `id` |
| out | `ping` (top level, no envelope) | Liveness |
| in | `pong` (top level) | Answers the ping |

The two `remove` payloads are not interchangeable: `workspace_update` uses
`id`, `agent_update` uses `agentId`.

Direct hosts send the password as both an `Authorization: Bearer` header and
a `paseo.bearer.<password>` WebSocket subprotocol, which the daemon echoes.
Relay hosts send no password: possession of the pairing offer is the
credential, and the daemon's password check runs only on direct upgrades.

Capabilities advertised in `hello` are the 0.4.0 client's set plus
`selective_agent_timeline`. Without that flag the daemon streams every
agent's timeline (`agent_stream`) to the client; the tray never views a
timeline, and through a relay that traffic is encrypted and forwarded for
nothing. With it, the daemon sends `agent_attention_required` only.

### Connection lifecycle, copied from the 0.4.0 client

`connected` means `server_info` received, not socket open. The relay accepts
a client socket even when the daemon is offline, so a client that trusts the
socket sits in "connected" forever with no data.

| Behaviour | Value |
| --- | --- |
| Connect timeout, transport open to `server_info` | 15 s |
| Reconnect backoff | 1.5 s × 2ⁿ, capped at 30 s; reset on connect |
| Ping interval once connected | 10 s |
| Pong timeout | 15 s |
| Unanswered pings before reconnect | 2 |
| Request timeout | 60 s |
| Seed retry while the socket stays up | 2 s |

Auth failure arrives as the close frame's reason, `Password required` or
`Incorrect password`, never as a thrown error. A host in that state reports
`unauthorized` and stops reconnecting; retrying a wrong password behind
backoff forever is the failure mode to avoid.

### Relay: end-to-end encryption

The relay is a transport wrapper under the unchanged daemon protocol. The
client dials `wss://<endpoint>/ws?serverId=<id>&role=client&v=2`; the hosted
default is `relay.paseo.sh:443` with TLS, and an offer that omits `useTls`
gets TLS exactly when the port is 443.

The channel is `@getpaseo/relay` 0.4.0 `encrypted-channel.ts`, client side:

- A fresh X25519 key pair per socket. Never reuse a shared key across
  reconnects; the daemon rejects a re-handshake with a different key with
  close code 1008.
- Shared key: `crypto_box_beforenm` of our secret and the daemon public key
  from the offer. A low-order peer key is refused.
- Handshake: plaintext `{"type":"e2ee_hello","key":"<base64 pk>","capabilities":{"binaryCiphertext":true}}`,
  resent every second until `{"type":"e2ee_ready", ...}` arrives. Ready
  carries no key. Frames sent before ready are queued, newest 200 kept.
- Every frame after: `nonce (24) || crypto_box_easy_afternm output`, that is
  `mac (16) || ciphertext`. Text plaintext travels base64 in a text frame.
  Binary plaintext travels as a binary frame when the daemon's ready carried
  `binaryCiphertext: true`, else base64. The tray only exchanges JSON, so in
  practice every frame is base64 text; binary frames are still decrypted.
- Stray `e2ee_hello` or `e2ee_ready` after open are ignored. Any other
  plaintext JSON after open is fatal: close 1011 and let the session
  reconnect. A frame that fails to decrypt is fatal the same way.

The crypto library is swift-sodium (`jedisct1/swift-sodium`, product
`Sodium`, pinned exactly). Its `Box.seal(message:beforenm:)` returns the wire
bundle above and `Box.open(nonceAndAuthenticatedCipherText:beforenm:)`
consumes it, so the channel has no framing code of its own. The macOS slice
of its `Clibsodium.xcframework` is a static archive, so signing needs no
extra step. Interop is proven against tweetnacl-generated vectors, not
assumed.

### Where logic goes

The Electron rule carries over with the toolkit swapped: **if it does not
touch AppKit or SwiftUI, it does not belong in the app target.** Everything
else lives in the `PaseoIconCore` library, takes its collaborators by
injection, and is tested without a menu bar.

| Module | Owns |
| --- | --- |
| `PaseoIcon` (executable) | The SwiftUI `App`, `MenuBarExtra`, the rendered label, dialogs, login item, `NSWorkspace.open`, the `fs` watch itself. Wiring only. |
| `PaseoIconProbe` (executable) | A terminal probe: dial one host, print transitions and counts. How relay connectivity is checked against a real host. |
| `PaseoIconCore/Config/HostEntry.swift` | The two host shapes, `endpointHint`. |
| `PaseoIconCore/Config/ConnectionOffer.swift` | The pairing offer and its URL fragment parser. |
| `PaseoIconCore/Daemon/DaemonEndpoints.swift` | `host:port` parsing, direct and relay URLs. |
| `PaseoIconCore/Daemon/E2EEBox.swift` | Key pairs, shared key, seal, open. All Sodium use lives here. |
| `PaseoIconCore/Daemon/E2EEChannel.swift` | The handshake and per-frame encryption, as a transport wrapping a transport. |
| `PaseoIconCore/Daemon/DaemonTransport.swift` | The transport protocol and `TransportFactory`. |
| `PaseoIconCore/Daemon/URLSessionWebSocketTransport.swift` | The real socket. |
| `PaseoIconCore/Daemon/DaemonMessages.swift` | The wire shapes above, Codable, lenient. |
| `PaseoIconCore/Daemon/DaemonSession.swift` | Hello, server_info, timeouts, backoff, liveness, request correlation, update streams. |
| `PaseoIconCore/Daemon/HostSink.swift` | What a connection reports into. The store implements it. |
| `PaseoIconCore/Daemon/HostConnection.swift` | One host: connect, seed both lists together, retry the seed, classify auth, report status. |
| `PaseoIconCore/Registry/…` | The LevelDB, WAL, snappy, and localStorage readers, ported from `src/registry/`. Later plan. |
| `PaseoIconCore/Store/…`, `…/Tray/…` | Host store, fleet, view model. Later plans. |

All session-layer classes are `@MainActor`. The TypeScript original was
single-threaded; keeping the port on one actor keeps its reasoning intact,
and the tray's traffic is small enough that hopping socket events to the main
actor costs nothing measurable.

### Testing

Swift Testing, with `TestClock` from `pointfreeco/swift-clocks` driving every
timer, so the hello retry, connect timeout, backoff, ping, and seed retry are
asserted to the second without real sleeps.

Three layers stand in for the SDK's guarantees:

1. **Vectors.** `scripts/make-e2ee-fixtures.mjs` generates key pairs, nonces,
   and bundles with tweetnacl, the library the daemon uses. The Swift tests
   derive the same shared key from both sides, decrypt every bundle, and
   re-encrypt to the same layout. The fixture is committed, like the LevelDB
   fixtures, so `swift test` needs no Node.
2. **Fakes.** A recording transport and a recording sink drive the channel,
   the session, and the host connection through every transition the
   Electron tests covered, plus the relay-only ones.
3. **Real processes.** Node harness scripts in `scripts/` boot a real
   `@getpaseo/server` 0.4.0 daemon and a `ws` echo server for the socket and
   end-to-end tests. The relay path runs through a local relay under
   `wrangler dev`, opt-in, because it needs a separate install and a minute.

What no test can see: the icon in the menu bar, click-through, login-item
registration, and behaviour against the user's real relay host. Those are
checked by a human running the probe and the app, and reported as such.

### Repository layout and migration

The Swift package lives in `PaseoIconPackage/` beside the Electron sources,
mirroring Gallager's layout. `scripts/` keeps its plain `.mjs` build and test
tooling and gains the Swift harnesses. The Electron app remains the shipped
product until the native app reaches parity; both build from the same
checkout, and the cask, release workflow, and this directory carry over. The
bundle stays `PaseoIcon.app`, because `scripts/render-cask.test.mjs` pins the
cask's `app` stanza to that name.

Plans, in order, each producing working tested software:

1. Foundation: package, offer and endpoints, E2EE channel, session, host
   connection, real-daemon and relay harnesses, the probe, an app skeleton.
2. Registry: the LevelDB reader port against the existing fixtures, the
   registry session and watcher.
3. Store, fleet, and view model: parity with the Electron menu, including
   the count, sections, overflow rows, and the error row.
4. Packaging: bundle assembly, signing, notarization, the cask's macOS floor,
   the release workflow.
5. UI beyond parity: whatever the menu could not do, now that it can.

## Deferred

Named so they are choices rather than omissions.

- **Notifications, agent actions, a shared host registry.** Deferred for the
  same reasons as in the standalone design.
- **A preferences window.** Still deferred. The window-style panel landed on
  2026-09-17 and is not one: it has no title bar, no Dock presence, and closes
  when it resigns key.
- **Intel builds.** Releases stay `arm64`; a universal binary is a packaging
  decision for plan 4.
- **A daemon-side sort key for the seed cap.** Unchanged from the known issue
  in `CLAUDE.md`.
