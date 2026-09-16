# Native App Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package that dials a Paseo daemon directly or through a relay with end-to-end encryption, seeds and streams its workspaces and agents into a sink, and proves it against a real daemon and a real relay, plus a probe CLI and a menu bar app skeleton.

**Architecture:** `PaseoIconCore` is a pure library: offer parsing, URL builders, the E2EE box and channel, a transport protocol with a `URLSession` implementation, the session state machine, and the per-host connection that a later store plugs into through `HostSink`. Every session-layer class is `@MainActor` and takes its clock and transport factory by injection, so timers and sockets are faked in tests. Two executables sit on top: `PaseoIconProbe` prints one host's transitions to a terminal, and `PaseoIcon` is the `MenuBarExtra` skeleton later plans complete.

**Tech Stack:** Swift 6.1 tools (Xcode 27 / Swift 6.4 on the maintainer's machine), Swift Package Manager, SwiftUI `MenuBarExtra`, Swift Testing, swift-sodium 0.11.0 (exact), swift-clocks 1.0.4+, Node 26 with `@getpaseo/server` 0.4.0, `ws`, `tweetnacl`, and `wrangler` for the harnesses.

**Spec:** `docs/superpowers/2026-09-16-native-swift-app-design.md` (binding for the native build). Behaviour rules come from `docs/superpowers/2026-08-16-standalone-menubar-app-design.md` and `docs/superpowers/2026-08-19-registry-sync-design.md`, both binding.

## Global Constraints

- The wire pin is `protocolVersion: 1` and the message shapes of `@getpaseo/protocol` **0.4.0**. Decoding is lenient: unknown fields ignored, enum-like strings kept as strings, only the messages in the spec's table parsed.
- Direct hosts send the password as `Authorization: Bearer <password>` **and** the `paseo.bearer.<password>` subprotocol. Relay hosts send no password.
- `connected` means `server_info` received, never socket open.
- Timings, verbatim from the 0.4.0 client: connect timeout 15 s; reconnect 1.5 s × 2ⁿ capped at 30 s, reset on connect; ping every 10 s; pong timeout 15 s; 2 unanswered pings reconnect; request timeout 60 s; seed retry 2 s.
- Auth rejection is the close reason `Password required` or `Incorrect password` and reports `unauthorized` with no further reconnects.
- Capabilities in `hello` are the 0.4.0 client's set plus `selective_agent_timeline: true`.
- Relay E2EE: fresh X25519 key pair per socket; `crypto_box_beforenm` shared key; `e2ee_hello` with `capabilities.binaryCiphertext: true` resent every 1 s until `e2ee_ready`; frames are `nonce(24) || crypto_box_easy_afternm`, base64 in text frames; newest 200 pre-ready sends queued; plaintext JSON after open other than stray hello/ready is fatal with close 1011.
- `swift-sodium` pinned `exact: "0.11.0"`, product `Sodium`. `swift-clocks` `from: "1.0.4"`, product `Clocks` (tests only).
- Package: `PaseoIconPackage/`, `swift-tools-version: 6.1`, `platforms: [.macOS(.v14)]`. Session-layer classes are `@MainActor`.
- The Electron app keeps shipping. `npx vitest run` and `npm run typecheck` stay green throughout. **Do not launch the Electron app** (`electron .`) to check anything.
- The bundle name stays `PaseoIcon.app`; no cask or release changes in this plan.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Run Swift tests from the repository root as `swift test --package-path PaseoIconPackage`. Integration tests spawn `node` from `PATH`; run `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install` first.

## Provenance

Every Swift file and Node script in this plan was written into a scratch copy of this layout, compiled with Xcode 27 (Swift 6.4), and run on 2026-09-16: 75 Swift tests green, the relay end-to-end test green through a local `wrangler dev` relay, the probe green against a real 0.4.0 daemon, and the fixture generator's vitest test green. If a toolchain difference surfaces a compile error, fix that error; do not re-derive the design.

## File Structure

| Path | Responsibility |
| --- | --- |
| `PaseoIconPackage/Package.swift` | Targets and pinned dependencies. |
| `PaseoIconPackage/Sources/PaseoIconCore/Config/HostEntry.swift` | The two host shapes and `endpointHint`. |
| `PaseoIconPackage/Sources/PaseoIconCore/Config/ConnectionOffer.swift` | The pairing offer and its `#offer=` URL parser. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonEndpoints.swift` | `host:port` parsing, direct and relay URLs. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEBox.swift` | Key pairs, shared key, seal, open. All Sodium use. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonTransport.swift` | The transport protocol, frames, close, factory. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEChannel.swift` | Handshake and per-frame encryption as a transport wrapping a transport. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonMessages.swift` | Codable wire shapes and the inbound parser. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonSession.swift` | Hello, server_info, timeouts, backoff, liveness, requests, streams. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostSink.swift` | What a connection reports into. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostConnection.swift` | One host: connect, seed, retry, classify auth, report. |
| `PaseoIconPackage/Sources/PaseoIconCore/Daemon/URLSessionWebSocketTransport.swift` | The real socket. |
| `PaseoIconPackage/Sources/PaseoIconProbe/main.swift` | Terminal probe. |
| `PaseoIconPackage/Sources/PaseoIcon/PaseoIconApp.swift` | `MenuBarExtra` skeleton. |
| `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/*.swift` | Fake transport, recorded sink, wire transcripts, Node harness runner. |
| `PaseoIconPackage/Tests/PaseoIconCoreTests/*Tests.swift` | One suite per module. |
| `PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/e2ee-vectors.json` | Generated tweetnacl vectors, committed. |
| `scripts/make-e2ee-fixtures.mjs` + `.test.mjs` | Generates and validates the vectors. |
| `scripts/swift-test-ws-echo.mjs` | `ws` echo server for the transport test. |
| `scripts/swift-test-daemon.mjs` | Boots a real 0.4.0 daemon for the Swift tests. |
| `scripts/swift-test-relay.mjs` + `scripts/relay-harness/` | Local relay under `wrangler dev` plus a daemon registered with it. |

---

### Task 1: Package skeleton, host entries, and the pairing offer parser

**Files:**
- Create: `PaseoIconPackage/Package.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Config/HostEntry.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Config/ConnectionOffer.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/HostEntryTests.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/ConnectionOfferTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces `HostEntry` (`.directTcp(id:label:endpoint:useTls:password:)`, `.relay(id:label:offer:)`, `.id`, `.label`, `.endpointHint`), `ConnectionOffer` (`serverId`, `daemonPublicKeyB64`, `relay.endpoint`, `relay.useTls`, `static parse(fromURL:) throws`, `validated() throws`), and `ConnectionOfferError`.

- [ ] **Step 1: Create the package manifest and the first source file**

`PaseoIconPackage/Package.swift` (this version has no executables; Tasks 10 and 11 add them):

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PaseoIconPackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaseoIconCore", targets: ["PaseoIconCore"]),
    ],
    dependencies: [
        // Pinned exactly: the E2EE wire format is libsodium's crypto_box, and the
        // xcframework this ships is a static archive, so signing needs no extra step.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
        // TestClock, so timers (hello retry, connect timeout, ping, backoff) are
        // tested deterministically instead of with real sleeps.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "PaseoIconCore",
            dependencies: [.product(name: "Sodium", package: "swift-sodium")]
        ),
        .testTarget(
            name: "PaseoIconCoreTests",
            dependencies: [
                "PaseoIconCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

Create the empty fixtures directory the manifest names, with a placeholder the resource bundle can copy (Task 3 replaces it with the real file):

```bash
mkdir -p PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures
echo '{}' > PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/e2ee-vectors.json
```

`PaseoIconPackage/Sources/PaseoIconCore/Config/HostEntry.swift`:

```swift
/// One host the tray dials. The shapes mirror `@getpaseo/protocol` 0.4.0:
/// `DirectTcpHostConnectionSchema` for `directTcp` and `ConnectionOfferSchema`
/// for `relay`. `label` is the user's explicit name; nil lets the tray fall
/// through to the daemon's own `hostname`.
public enum HostEntry: Equatable, Sendable {
    case directTcp(id: String, label: String?, endpoint: String, useTls: Bool, password: String?)
    case relay(id: String, label: String?, offer: ConnectionOffer)

    public var id: String {
        switch self {
        case .directTcp(let id, _, _, _, _), .relay(let id, _, _): id
        }
    }

    public var label: String? {
        switch self {
        case .directTcp(_, let label, _, _, _), .relay(_, let label, _): label
        }
    }

    /// The last-resort display name: the network address the entry dials. A
    /// relay entry has no daemon-facing address before it connects, so the
    /// relay's own endpoint stands in.
    public var endpointHint: String {
        switch self {
        case .directTcp(_, _, let endpoint, _, _): endpoint
        case .relay(_, _, let offer): offer.relay.endpoint
        }
    }
}
```

Append to `.gitignore`:

```
PaseoIconPackage/.build/
scripts/relay-harness/.wrangler/
```

- [ ] **Step 2: Write the failing tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/HostEntryTests.swift`:

```swift
import Testing
@testable import PaseoIconCore

struct HostEntryTests {
    private let offer = ConnectionOffer(serverId: "srv-1", daemonPublicKeyB64: "k", relay: .init(endpoint: "relay.paseo.sh:443"))

    @Test("exposes id and label for both shapes")
    func idAndLabel() {
        let direct = HostEntry.directTcp(id: "d", label: "Desk", endpoint: "127.0.0.1:6767", useTls: false, password: nil)
        let relay = HostEntry.relay(id: "r", label: nil, offer: offer)
        #expect(direct.id == "d")
        #expect(direct.label == "Desk")
        #expect(relay.id == "r")
        #expect(relay.label == nil)
    }

    @Test("the endpoint hint is the address the entry dials")
    func endpointHint() {
        let direct = HostEntry.directTcp(id: "d", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: nil)
        let relay = HostEntry.relay(id: "r", label: nil, offer: offer)
        #expect(direct.endpointHint == "127.0.0.1:6767")
        #expect(relay.endpointHint == "relay.paseo.sh:443")
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/ConnectionOfferTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct ConnectionOfferTests {
    private static let offerJSON = #"{"v":2,"serverId":"srv-1","daemonPublicKeyB64":"AAAA","relay":{"endpoint":"relay.paseo.sh:443"}}"#

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("parses the fragment of a pairing URL")
    func parsesFragment() throws {
        let url = "paseo://pair#offer=\(Self.base64URL(Self.offerJSON))"
        let offer = try ConnectionOffer.parse(fromURL: url)
        #expect(offer.serverId == "srv-1")
        #expect(offer.daemonPublicKeyB64 == "AAAA")
        #expect(offer.relay.endpoint == "relay.paseo.sh:443")
        #expect(offer.relay.useTls == nil)
    }

    @Test("accepts a bare fragment and surrounding whitespace")
    func bareFragment() throws {
        let offer = try ConnectionOffer.parse(fromURL: "  #offer=\(Self.base64URL(Self.offerJSON))\n")
        #expect(offer.serverId == "srv-1")
    }

    @Test("rejects input without an offer fragment")
    func missingFragment() {
        #expect(throws: ConnectionOfferError.missingFragment) {
            try ConnectionOffer.parse(fromURL: "https://app.paseo.sh/")
        }
    }

    @Test("rejects an offer version other than 2")
    func wrongVersion() {
        let json = #"{"v":3,"serverId":"s","daemonPublicKeyB64":"k","relay":{"endpoint":"r:443"}}"#
        #expect(throws: ConnectionOfferError.unsupportedVersion(3)) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL(json))")
        }
    }

    @Test("rejects an empty serverId")
    func emptyServerId() {
        let json = #"{"v":2,"serverId":"","daemonPublicKeyB64":"k","relay":{"endpoint":"r:443"}}"#
        #expect(throws: ConnectionOfferError.emptyField("serverId")) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL(json))")
        }
    }

    @Test("rejects base64 that is not JSON")
    func notJSON() {
        #expect(throws: ConnectionOfferError.self) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL("not json"))")
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path PaseoIconPackage --filter ConnectionOfferTests`
Expected: the first build resolves and compiles swift-sodium and swift-clocks (a minute), then fails with `error: cannot find 'ConnectionOffer' in scope`.

- [ ] **Step 4: Write the offer parser**

`PaseoIconPackage/Sources/PaseoIconCore/Config/ConnectionOffer.swift`:

```swift
import Foundation

/// A relay pairing offer, exactly as `paseo daemon pair` issues it and the
/// Paseo app stores it. `v` is pinned to 2: that is the only shape the 0.4.0
/// protocol defines, and an offer of another version is rejected rather than
/// guessed at.
public struct ConnectionOffer: Codable, Equatable, Sendable {
    public struct Relay: Codable, Equatable, Sendable {
        public var endpoint: String
        public var useTls: Bool?

        public init(endpoint: String, useTls: Bool? = nil) {
            self.endpoint = endpoint
            self.useTls = useTls
        }
    }

    public var v: Int
    public var serverId: String
    public var daemonPublicKeyB64: String
    public var relay: Relay

    public init(serverId: String, daemonPublicKeyB64: String, relay: Relay) {
        self.v = 2
        self.serverId = serverId
        self.daemonPublicKeyB64 = daemonPublicKeyB64
        self.relay = relay
    }
}

public enum ConnectionOfferError: Error, Equatable {
    case missingFragment
    case invalidBase64
    case invalidJSON(String)
    case unsupportedVersion(Int)
    case emptyField(String)
}

extension ConnectionOffer {
    static let fragmentPrefix = "#offer="

    /// Parses the URL `paseo daemon pair` prints. The offer rides in the URL
    /// fragment as base64url JSON; anything before `#offer=` is ignored, so a
    /// bare fragment and a full `paseo://` or `https://` URL both parse.
    public static func parse(fromURL input: String) throws -> ConnectionOffer {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: fragmentPrefix) else {
            throw ConnectionOfferError.missingFragment
        }
        let encoded = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { throw ConnectionOfferError.missingFragment }
        guard let data = decodeBase64URL(encoded) else { throw ConnectionOfferError.invalidBase64 }
        let offer: ConnectionOffer
        do {
            offer = try JSONDecoder().decode(ConnectionOffer.self, from: data)
        } catch {
            throw ConnectionOfferError.invalidJSON(String(describing: error))
        }
        return try offer.validated()
    }

    /// The offer's own invariants: version 2 and no empty identifiers. Applied
    /// to parsed offers and to offers assembled from the registry alike.
    public func validated() throws -> ConnectionOffer {
        guard v == 2 else { throw ConnectionOfferError.unsupportedVersion(v) }
        guard !serverId.isEmpty else { throw ConnectionOfferError.emptyField("serverId") }
        guard !daemonPublicKeyB64.isEmpty else { throw ConnectionOfferError.emptyField("daemonPublicKeyB64") }
        guard !relay.endpoint.isEmpty else { throw ConnectionOfferError.emptyField("relay.endpoint") }
        return self
    }

    static func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 8 tests in 2 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add .gitignore PaseoIconPackage
git commit -m "feat(native): Swift package skeleton with host entries and the offer parser

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Endpoint parsing and URL builders

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonEndpoints.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/DaemonEndpointsTests.swift`

**Interfaces:**
- Consumes nothing from Task 1.
- Produces `DaemonEndpoints.parseHostPort(_:) throws -> HostPort`, `daemonWebSocketURL(endpoint:useTls:) throws -> URL`, `relayWebSocketURL(endpoint:useTls:serverId:) throws -> URL`, `shouldUseTlsForDefaultHostedRelay(_:) -> Bool`, `HostPort`, `DaemonEndpointError`.

- [ ] **Step 1: Write the failing test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/DaemonEndpointsTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct DaemonEndpointsTests {
    @Test("parses host:port")
    func hostPort() throws {
        let parsed = try DaemonEndpoints.parseHostPort("localhost:6767")
        #expect(parsed == HostPort(host: "localhost", port: 6767, isIPv6: false))
    }

    @Test("parses a bracketed IPv6 host")
    func ipv6() throws {
        let parsed = try DaemonEndpoints.parseHostPort("[::1]:6767")
        #expect(parsed == HostPort(host: "::1", port: 6767, isIPv6: true))
    }

    @Test("rejects a missing port and an out-of-range port")
    func badPorts() {
        #expect(throws: DaemonEndpointError.self) { try DaemonEndpoints.parseHostPort("localhost") }
        #expect(throws: DaemonEndpointError.invalidPort("70000")) { try DaemonEndpoints.parseHostPort("localhost:70000") }
        #expect(throws: DaemonEndpointError.hostRequired) { try DaemonEndpoints.parseHostPort("  ") }
    }

    @Test("builds the direct daemon URL at /ws")
    func daemonURL() throws {
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "127.0.0.1:6767", useTls: false).absoluteString == "ws://127.0.0.1:6767/ws")
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "host.example:443", useTls: true).absoluteString == "wss://host.example:443/ws")
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "[::1]:6767", useTls: false).absoluteString == "ws://[::1]:6767/ws")
    }

    @Test("builds the relay client URL with serverId, role, and v=2")
    func relayURL() throws {
        let url = try DaemonEndpoints.relayWebSocketURL(endpoint: "relay.paseo.sh:443", useTls: true, serverId: "srv 1")
        #expect(url.absoluteString == "wss://relay.paseo.sh:443/ws?serverId=srv%201&role=client&v=2")
    }

    @Test("the hosted relay default is TLS on 443 only")
    func hostedRelayTls() {
        #expect(DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("relay.paseo.sh:443"))
        #expect(!DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("127.0.0.1:8787"))
        #expect(!DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("garbage"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter DaemonEndpointsTests`
Expected: `error: cannot find 'DaemonEndpoints' in scope`.

- [ ] **Step 3: Write the implementation**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonEndpoints.swift`:

```swift
import Foundation

public struct HostPort: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let isIPv6: Bool
}

public enum DaemonEndpointError: Error, Equatable {
    case hostRequired
    case invalidHostPort(String)
    case invalidPort(String)
    case invalidURL(String)
}

/// URL builders copied from `@getpaseo/protocol` 0.4.0 `daemon-endpoints`.
/// A direct daemon listens at `/ws`; the relay takes the same path plus the
/// session id, the caller's role, and the relay protocol version.
public enum DaemonEndpoints {
    /// `CURRENT_RELAY_PROTOCOL_VERSION` upstream. Version 2 is the per-connection
    /// data-socket design; the relay rejects anything else with a 400.
    public static let relayProtocolVersion = "2"
    public static let defaultHostedRelayPort = 443

    public static func parseHostPort(_ input: String) throws -> HostPort {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DaemonEndpointError.hostRequired }
        if trimmed.hasPrefix("[") {
            guard let match = trimmed.wholeMatch(of: #/^\[([^\]]+)\]:(\d{1,5})$/#) else {
                throw DaemonEndpointError.invalidHostPort("expected [::1]:6767")
            }
            let host = match.1.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { throw DaemonEndpointError.hostRequired }
            return HostPort(host: host, port: try parsePort(String(match.2)), isIPv6: true)
        }
        guard let match = trimmed.wholeMatch(of: #/^(.+):(\d{1,5})$/#) else {
            throw DaemonEndpointError.invalidHostPort("expected localhost:6767")
        }
        let host = match.1.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw DaemonEndpointError.hostRequired }
        return HostPort(host: host, port: try parsePort(String(match.2)), isIPv6: false)
    }

    public static func daemonWebSocketURL(endpoint: String, useTls: Bool) throws -> URL {
        let parsed = try parseHostPort(endpoint)
        return try baseURL(parsed, useTls: useTls)
    }

    public static func relayWebSocketURL(endpoint: String, useTls: Bool, serverId: String) throws -> URL {
        let parsed = try parseHostPort(endpoint)
        let base = try baseURL(parsed, useTls: useTls)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DaemonEndpointError.invalidURL(base.absoluteString)
        }
        components.queryItems = [
            URLQueryItem(name: "serverId", value: serverId),
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "v", value: relayProtocolVersion),
        ]
        guard let url = components.url else { throw DaemonEndpointError.invalidURL(base.absoluteString) }
        return url
    }

    /// The hosted relay terminates TLS on 443 and an offer may omit `useTls`;
    /// this is the default the CLI applies in that case.
    public static func shouldUseTlsForDefaultHostedRelay(_ endpoint: String) -> Bool {
        guard let parsed = try? parseHostPort(endpoint) else { return false }
        return parsed.port == defaultHostedRelayPort
    }

    private static func baseURL(_ hostPort: HostPort, useTls: Bool) throws -> URL {
        let scheme = useTls ? "wss" : "ws"
        let hostPart = hostPort.isIPv6 ? "[\(hostPort.host)]" : hostPort.host
        let text = "\(scheme)://\(hostPart):\(hostPort.port)/ws"
        guard let url = URL(string: text) else { throw DaemonEndpointError.invalidURL(text) }
        return url
    }

    private static func parsePort(_ text: String) throws -> Int {
        guard let port = Int(text), (1...65535).contains(port) else {
            throw DaemonEndpointError.invalidPort(text)
        }
        return port
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 14 tests in 3 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): daemon and relay URL builders copied from protocol 0.4.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: E2EE vectors from tweetnacl and the Sodium box

**Files:**
- Modify: `package.json` (devDependencies, scripts)
- Create: `scripts/make-e2ee-fixtures.mjs`
- Create: `scripts/make-e2ee-fixtures.test.mjs`
- Create (generated): `PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/e2ee-vectors.json`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEBox.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/E2EEBoxTests.swift`

**Interfaces:**
- Produces `E2EEBox.generateKeyPair() -> E2EEKeyPair`, `importPublicKey(base64:) throws -> [UInt8]`, `exportPublicKey(_:) -> String`, `deriveSharedKey(ourSecretKey:peerPublicKey:) throws -> E2EESharedKey`, `encrypt(_:with:) throws -> [UInt8]`, `decrypt(_:with:) throws -> [UInt8]`, constants `nonceLength = 24`, `macLength = 16`, `overheadLength = 40`, and `E2EEBoxError`.

- [ ] **Step 1: Add the Node dependencies and scripts**

In `package.json`, add to `"devDependencies"` (both are already in the lockfile transitively; naming them makes the scripts' imports legitimate):

```json
    "tweetnacl": "^1.0.3",
    "ws": "^8.21.3",
```

and to `"scripts"`:

```json
    "fixtures:e2ee": "node scripts/make-e2ee-fixtures.mjs PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/e2ee-vectors.json",
    "test:swift": "swift test --package-path PaseoIconPackage",
```

Then run: `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install`
Expected: the lockfile gains the two direct entries and nothing else changes.

- [ ] **Step 2: Write the generator and its vitest test**

`scripts/make-e2ee-fixtures.mjs`:

```javascript
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
```

`scripts/make-e2ee-fixtures.test.mjs`:

```javascript
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
```

- [ ] **Step 3: Generate the fixture and run the vitest test**

Run: `npm run fixtures:e2ee && npx vitest run scripts/make-e2ee-fixtures.test.mjs`
Expected: `wrote 6 vectors to PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/e2ee-vectors.json`, then `Tests  2 passed (2)`.

- [ ] **Step 4: Write the failing Swift test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/E2EEBoxTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// Interop with tweetnacl, which `@getpaseo/relay` wraps. The vectors are
/// generated by `scripts/make-e2ee-fixtures.mjs`; matching their bytes means
/// matching the daemon.
struct E2EEBoxTests {
    struct Fixture: Decodable {
        struct Vector: Decodable {
            let name: String
            let isBinary: Bool
            let daemonPublicKeyB64: String
            let daemonSecretKeyB64: String
            let clientPublicKeyB64: String
            let clientSecretKeyB64: String
            let sharedKeyB64: String
            let nonceB64: String
            let plaintextB64: String
            let bundleB64: String
        }

        let lowOrderPublicKeyB64: String
        let vectors: [Vector]
    }

    static func loadFixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "e2ee-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func bytes(_ base64: String) throws -> [UInt8] {
        [UInt8](try #require(Data(base64Encoded: base64)))
    }

    @Test("derives the same shared key tweetnacl derived, from either side")
    func sharedKey() throws {
        for vector in try Self.loadFixture().vectors {
            let expected = E2EESharedKey(bytes: try Self.bytes(vector.sharedKeyB64))
            let client = try E2EEBox.deriveSharedKey(
                ourSecretKey: try Self.bytes(vector.clientSecretKeyB64),
                peerPublicKey: try E2EEBox.importPublicKey(base64: vector.daemonPublicKeyB64)
            )
            let daemon = try E2EEBox.deriveSharedKey(
                ourSecretKey: try Self.bytes(vector.daemonSecretKeyB64),
                peerPublicKey: try E2EEBox.importPublicKey(base64: vector.clientPublicKeyB64)
            )
            #expect(client == expected, "\(vector.name)")
            #expect(daemon == expected, "\(vector.name)")
        }
    }

    @Test("decrypts every tweetnacl bundle")
    func decryptsVectors() throws {
        for vector in try Self.loadFixture().vectors {
            let key = E2EESharedKey(bytes: try Self.bytes(vector.sharedKeyB64))
            let plaintext = try E2EEBox.decrypt(try Self.bytes(vector.bundleB64), with: key)
            #expect(plaintext == (try Self.bytes(vector.plaintextB64)), "\(vector.name)")
        }
    }

    @Test("encrypts to a bundle tweetnacl's layout describes, and round-trips")
    func encryptsRoundTrip() throws {
        for vector in try Self.loadFixture().vectors {
            let key = E2EESharedKey(bytes: try Self.bytes(vector.sharedKeyB64))
            let plaintext = try Self.bytes(vector.plaintextB64)
            let bundle = try E2EEBox.encrypt(plaintext, with: key)
            #expect(bundle.count == plaintext.count + E2EEBox.overheadLength, "\(vector.name)")
            #expect(try E2EEBox.decrypt(bundle, with: key) == plaintext, "\(vector.name)")
        }
    }

    @Test("a tampered bundle does not decrypt")
    func tamperDetected() throws {
        let vector = try #require(try Self.loadFixture().vectors.first { $0.name == "hello-json" })
        let key = E2EESharedKey(bytes: try Self.bytes(vector.sharedKeyB64))
        var bundle = try Self.bytes(vector.bundleB64)
        bundle[bundle.count - 1] ^= 0x01
        #expect(throws: E2EEBoxError.decryptionFailed) { try E2EEBox.decrypt(bundle, with: key) }
    }

    @Test("a bundle shorter than a nonce is rejected before decryption")
    func tooShort() {
        let key = E2EESharedKey(bytes: [UInt8](repeating: 1, count: 32))
        #expect(throws: E2EEBoxError.bundleTooShort(5)) { try E2EEBox.decrypt([1, 2, 3, 4, 5], with: key) }
    }

    @Test("a low-order peer key is refused, as tweetnacl's deriveSharedKey refuses it")
    func lowOrderKey() throws {
        let fixture = try Self.loadFixture()
        let pair = E2EEBox.generateKeyPair()
        #expect(throws: E2EEBoxError.lowOrderPublicKey) {
            try E2EEBox.deriveSharedKey(
                ourSecretKey: pair.secretKey,
                peerPublicKey: try E2EEBox.importPublicKey(base64: fixture.lowOrderPublicKeyB64)
            )
        }
    }

    @Test("public key import checks base64 and length")
    func importChecks() {
        #expect(throws: E2EEBoxError.invalidBase64) { try E2EEBox.importPublicKey(base64: "***") }
        #expect(throws: E2EEBoxError.invalidPublicKeyLength(3)) { try E2EEBox.importPublicKey(base64: "AAAA") }
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter E2EEBoxTests`
Expected: `error: cannot find 'E2EEBox' in scope`.

- [ ] **Step 6: Write the box**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEBox.swift`:

```swift
import Foundation
import Sodium

public struct E2EEKeyPair: Sendable {
    public let publicKey: [UInt8]
    public let secretKey: [UInt8]
}

public struct E2EESharedKey: Equatable, Sendable {
    public let bytes: [UInt8]
}

public enum E2EEBoxError: Error, Equatable {
    case invalidBase64
    case invalidPublicKeyLength(Int)
    case invalidSecretKeyLength(Int)
    case lowOrderPublicKey
    case bundleTooShort(Int)
    case decryptionFailed
    case encryptionFailed
}

/// The relay's end-to-end encryption primitive, byte-compatible with
/// `@getpaseo/relay` 0.4.0 `crypto.ts` (tweetnacl `box`):
///
/// - key exchange: X25519, precomputed with `crypto_box_beforenm`
/// - cipher: XSalsa20-Poly1305 (`crypto_box_easy_afternm`)
/// - wire bundle: `[nonce (24)] [mac (16)] [ciphertext]`
///
/// swift-sodium's `seal(message:beforenm:)` returns exactly that bundle and
/// `open(nonceAndAuthenticatedCipherText:beforenm:)` consumes it, so there is
/// no framing code here to get wrong. Verified against tweetnacl-generated
/// vectors in `E2EEBoxTests`.
public enum E2EEBox {
    public static let publicKeyLength = 32
    public static let secretKeyLength = 32
    public static let nonceLength = 24
    public static let macLength = 16
    public static var overheadLength: Int { nonceLength + macLength }

    public static func generateKeyPair() -> E2EEKeyPair {
        // libsodium's keypair generation only fails before sodium_init, which
        // Sodium() performs; a nil here is unreachable.
        let pair = Sodium().box.keyPair()!
        return E2EEKeyPair(publicKey: pair.publicKey, secretKey: pair.secretKey)
    }

    public static func importPublicKey(base64: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: base64) else { throw E2EEBoxError.invalidBase64 }
        guard data.count == publicKeyLength else { throw E2EEBoxError.invalidPublicKeyLength(data.count) }
        return [UInt8](data)
    }

    public static func exportPublicKey(_ key: [UInt8]) -> String {
        Data(key).base64EncodedString()
    }

    /// `crypto_box_beforenm`. libsodium rejects a peer key whose shared point is
    /// all zeros (a low-order point) by returning nil, which is the same check
    /// tweetnacl's `deriveSharedKey` performs by hand.
    public static func deriveSharedKey(ourSecretKey: [UInt8], peerPublicKey: [UInt8]) throws -> E2EESharedKey {
        guard ourSecretKey.count == secretKeyLength else {
            throw E2EEBoxError.invalidSecretKeyLength(ourSecretKey.count)
        }
        guard peerPublicKey.count == publicKeyLength else {
            throw E2EEBoxError.invalidPublicKeyLength(peerPublicKey.count)
        }
        guard let shared = Sodium().box.beforenm(recipientPublicKey: peerPublicKey, senderSecretKey: ourSecretKey) else {
            throw E2EEBoxError.lowOrderPublicKey
        }
        return E2EESharedKey(bytes: shared)
    }

    /// Returns `nonce || mac || ciphertext` with a fresh random nonce.
    public static func encrypt(_ plaintext: [UInt8], with key: E2EESharedKey) throws -> [UInt8] {
        guard let sealed: Bytes = Sodium().box.seal(message: plaintext, beforenm: key.bytes) else {
            throw E2EEBoxError.encryptionFailed
        }
        return sealed
    }

    public static func decrypt(_ bundle: [UInt8], with key: E2EESharedKey) throws -> [UInt8] {
        guard bundle.count >= nonceLength else { throw E2EEBoxError.bundleTooShort(bundle.count) }
        guard let opened: Bytes = Sodium().box.open(nonceAndAuthenticatedCipherText: bundle, beforenm: key.bytes) else {
            throw E2EEBoxError.decryptionFailed
        }
        return opened
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 21 tests in 4 suites passed`.

- [ ] **Step 8: Mutate to prove the vectors bite**

In `E2EEBox.decrypt`, temporarily change `bundle.count >= nonceLength` to `bundle.count >= 1` and in `encrypt` temporarily return `Array(sealed.dropFirst())`. Run `swift test --package-path PaseoIconPackage --filter E2EEBoxTests`.
Expected: `encrypts to a bundle tweetnacl's layout describes, and round-trips` and `a bundle shorter than a nonce is rejected before decryption` fail. Revert both edits and confirm green again.

- [ ] **Step 9: Commit**

```bash
git add package.json package-lock.json scripts/make-e2ee-fixtures.mjs scripts/make-e2ee-fixtures.test.mjs PaseoIconPackage
git commit -m "feat(native): E2EE box over swift-sodium, proven against tweetnacl vectors

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The transport protocol and the encrypted channel

> **Amended after execution.** The `E2EEChannel.swift` block below is what the executor transcribed; two review fixes changed it afterwards. `connect()` now resets every per-socket field so a channel can be connected again (commit 63f92cd), and `fail(_:)` now forwards the 1011 close to the channel's owner through `handleBaseClose`, because a client-initiated close never comes back from `URLSessionWebSocketTransport` (final review fix). Read the committed file, not this block.

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonTransport.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEChannel.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/FakeTransport.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/E2EEChannelTests.swift`

**Interfaces:**
- Consumes `E2EEBox` from Task 3.
- Produces `DaemonTransport` (`onOpen`, `onFrame`, `onClose`, `onError`, `connect()`, `send(_:)`, `close(code:reason:)`), `TransportFrame` (`.text`, `.binary`), `TransportClose(code:reason:)`, `TransportRequest(url:headers:subprotocols:)`, `TransportFactory`, and `E2EEChannel(base:daemonPublicKeyB64:clock:) throws` which is itself a `DaemonTransport`.
- Test support produces `FakeTransport` (`simulateOpen()`, `simulateText(_:)`, `simulateBinary(_:)`, `simulateClose(code:reason:)`, `sentText`, `sentBinary`, `closedWith`, `connectCalls`, `clearSent()`), `FakeTransportFactory` (`make(_:)`, `transports`, `last`), `settle()`, and `jsonObject(_:)`.

- [ ] **Step 1: Write the transport protocol**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonTransport.swift`:

```swift
import Foundation

public enum TransportFrame: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
}

public struct TransportClose: Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct TransportRequest: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let subprotocols: [String]

    public init(url: URL, headers: [String: String] = [:], subprotocols: [String] = []) {
        self.url = url
        self.headers = headers
        self.subprotocols = subprotocols
    }
}

/// One WebSocket-shaped connection. `URLSessionWebSocketTransport` is the real
/// one; `E2EEChannel` wraps another transport and is one itself, which is how
/// the session stays unaware of whether a host is direct or relayed. Every
/// callback fires on the main actor.
@MainActor
public protocol DaemonTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onFrame: ((TransportFrame) -> Void)? { get set }
    var onClose: ((TransportClose) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect()
    func send(_ frame: TransportFrame)
    func close(code: Int, reason: String)
}

public typealias TransportFactory = @MainActor (TransportRequest) -> any DaemonTransport
```

- [ ] **Step 2: Write the fake transport and the failing channel test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/FakeTransport.swift`:

```swift
import Foundation
@testable import PaseoIconCore

/// A transport the test drives by hand. Records what the code under test sent
/// and lets the test play the server's side.
@MainActor
final class FakeTransport: DaemonTransport {
    var onOpen: (() -> Void)?
    var onFrame: ((TransportFrame) -> Void)?
    var onClose: ((TransportClose) -> Void)?
    var onError: ((String) -> Void)?

    let request: TransportRequest
    private(set) var connectCalls = 0
    private(set) var sent: [TransportFrame] = []
    private(set) var closedWith: TransportClose?

    init(request: TransportRequest) {
        self.request = request
    }

    var sentText: [String] {
        sent.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    var sentBinary: [[UInt8]] {
        sent.compactMap { if case .binary(let bytes) = $0 { bytes } else { nil } }
    }

    func connect() { connectCalls += 1 }
    func send(_ frame: TransportFrame) { sent.append(frame) }
    func close(code: Int, reason: String) {
        guard closedWith == nil else { return }
        closedWith = TransportClose(code: code, reason: reason)
    }

    func clearSent() { sent = [] }
    func simulateOpen() { onOpen?() }
    func simulateText(_ text: String) { onFrame?(.text(text)) }
    func simulateBinary(_ bytes: [UInt8]) { onFrame?(.binary(bytes)) }
    func simulateClose(code: Int, reason: String) { onClose?(TransportClose(code: code, reason: reason)) }
}

@MainActor
final class FakeTransportFactory {
    private(set) var transports: [FakeTransport] = []

    func make(_ request: TransportRequest) -> any DaemonTransport {
        let transport = FakeTransport(request: request)
        transports.append(transport)
        return transport
    }

    var last: FakeTransport? { transports.last }
}

/// Lets tasks the code under test spawned run to their next suspension point.
/// Needed before advancing a `TestClock`, because a sleep only registers with
/// the clock once its task has started.
@MainActor
func settle() async {
    for _ in 0..<25 { await Task.yield() }
}

func jsonObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw NSError(domain: "FakeTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object: \(text)"])
    }
    return object
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/E2EEChannelTests.swift`:

```swift
import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct E2EEChannelTests {
    /// Records the channel's outward-facing events.
    @MainActor
    final class Recorder {
        var opens = 0
        var frames: [TransportFrame] = []
        var closes: [TransportClose] = []
        var errors: [String] = []
    }

    @MainActor
    struct Harness {
        let clock = TestClock()
        let base: FakeTransport
        let channel: E2EEChannel
        let daemon = E2EEBox.generateKeyPair()
        let recorder = Recorder()

        init() throws {
            base = FakeTransport(request: TransportRequest(url: URL(string: "wss://relay.test/ws")!))
            channel = try E2EEChannel(
                base: base,
                daemonPublicKeyB64: E2EEBox.exportPublicKey(daemon.publicKey),
                clock: clock
            )
            channel.onOpen = { [recorder] in recorder.opens += 1 }
            channel.onFrame = { [recorder] frame in recorder.frames.append(frame) }
            channel.onClose = { [recorder] close in recorder.closes.append(close) }
            channel.onError = { [recorder] message in recorder.errors.append(message) }
            channel.connect()
        }

        /// The daemon's view of the shared key, derived from the client key in the hello.
        func daemonSharedKey() throws -> E2EESharedKey {
            let hello = try jsonObject(try #require(base.sentText.first))
            let clientKey = try E2EEBox.importPublicKey(base64: try #require(hello["key"] as? String))
            return try E2EEBox.deriveSharedKey(ourSecretKey: daemon.secretKey, peerPublicKey: clientKey)
        }

        func ready(binaryCiphertext: Bool = true) {
            let capabilities = binaryCiphertext ? #","capabilities":{"binaryCiphertext":true}"# : ""
            base.simulateText(#"{"type":"e2ee_ready"\#(capabilities)}"#)
        }

        func daemonEncrypt(_ text: String) throws -> String {
            Data(try E2EEBox.encrypt(Array(text.utf8), with: try daemonSharedKey())).base64EncodedString()
        }

        func daemonDecrypt(_ base64: String) throws -> String {
            let bundle = [UInt8](try #require(Data(base64Encoded: base64)))
            return String(decoding: try E2EEBox.decrypt(bundle, with: try daemonSharedKey()), as: UTF8.self)
        }
    }

    @Test("sends e2ee_hello with our public key on base open")
    func sendsHello() throws {
        let h = try Harness()
        #expect(h.base.connectCalls == 1)
        h.base.simulateOpen()
        let hello = try jsonObject(try #require(h.base.sentText.first))
        #expect(hello["type"] as? String == "e2ee_hello")
        let key = try #require(hello["key"] as? String)
        #expect(try E2EEBox.importPublicKey(base64: key).count == 32)
        let capabilities = try #require(hello["capabilities"] as? [String: Any])
        #expect(capabilities["binaryCiphertext"] as? Bool == true)
        #expect(h.recorder.opens == 0)
    }

    @Test("retries the hello every second until ready arrives")
    func retriesHello() async throws {
        let h = try Harness()
        h.base.simulateOpen()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle()
        #expect(h.base.sentText.count == 2)
        await h.clock.advance(by: .seconds(1))
        await settle()
        #expect(h.base.sentText.count == 3)
        #expect(Set(h.base.sentText).count == 1, "every retry resends the same hello")
        h.ready()
        #expect(h.recorder.opens == 1)
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.base.sentText.count == 3, "no retries after ready")
    }

    @Test("queues frames sent before ready and flushes them encrypted")
    func queuesUntilReady() throws {
        let h = try Harness()
        h.channel.send(.text("before open"))
        h.base.simulateOpen()
        h.channel.send(.text("during handshake"))
        #expect(h.base.sentText.count == 1, "only the hello has gone out")
        h.ready()
        let encrypted = Array(h.base.sentText.dropFirst())
        #expect(encrypted.count == 2)
        #expect(try h.daemonDecrypt(encrypted[0]) == "before open")
        #expect(try h.daemonDecrypt(encrypted[1]) == "during handshake")
    }

    @Test("keeps only the newest 200 queued frames")
    func queueCap() throws {
        let h = try Harness()
        h.base.simulateOpen()
        for index in 0..<205 { h.channel.send(.text("m\(index)")) }
        h.ready()
        let encrypted = Array(h.base.sentText.dropFirst())
        #expect(encrypted.count == 200)
        #expect(try h.daemonDecrypt(encrypted[0]) == "m5")
    }

    @Test("decrypts base64 text frames from the daemon")
    func decryptsText() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.ready()
        h.base.simulateText(try h.daemonEncrypt(#"{"type":"pong"}"#))
        #expect(h.recorder.frames == [.text(#"{"type":"pong"}"#)])
    }

    @Test("decrypts binary frames from the daemon as bytes")
    func decryptsBinary() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.ready()
        let bundle = try E2EEBox.encrypt([9, 8, 7], with: try h.daemonSharedKey())
        h.base.simulateBinary(bundle)
        #expect(h.recorder.frames == [.binary([9, 8, 7])])
    }

    @Test("sends binary plaintext as a binary frame only when the daemon negotiated it")
    func binaryNegotiation() throws {
        let negotiated = try Harness()
        negotiated.base.simulateOpen()
        negotiated.ready(binaryCiphertext: true)
        negotiated.channel.send(.binary([1, 2, 3]))
        #expect(negotiated.base.sentBinary.count == 1)
        #expect(try E2EEBox.decrypt(negotiated.base.sentBinary[0], with: try negotiated.daemonSharedKey()) == [1, 2, 3])

        let legacy = try Harness()
        legacy.base.simulateOpen()
        legacy.ready(binaryCiphertext: false)
        legacy.channel.send(.binary([1, 2, 3]))
        #expect(legacy.base.sentBinary.isEmpty)
        #expect(legacy.base.sentText.count == 2, "hello plus one base64 frame")
    }

    @Test("ignores stray hello and ready messages after open")
    func ignoresStrayHandshake() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.ready()
        h.base.simulateText(#"{"type":"e2ee_hello","key":"AAAA"}"#)
        h.base.simulateText(#"{"type":"e2ee_ready"}"#)
        #expect(h.recorder.frames.isEmpty)
        #expect(h.base.closedWith == nil)
    }

    @Test("a plaintext frame after open is fatal: close 1011 so the session re-handshakes")
    func plaintextIsFatal() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.ready()
        h.base.simulateText(#"{"type":"session","message":{"type":"pong"}}"#)
        #expect(h.base.closedWith == TransportClose(code: 1011, reason: "Received plaintext frame on encrypted channel"))
        #expect(h.recorder.frames.isEmpty)
    }

    @Test("a frame that fails to decrypt is fatal")
    func badCiphertextIsFatal() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.ready()
        h.base.simulateText(Data([UInt8](repeating: 0, count: 60)).base64EncodedString())
        #expect(h.base.closedWith?.code == 1011)
        #expect(h.base.closedWith?.reason == "Decryption failed")
    }

    @Test("forwards the base close once and stops retrying the hello")
    func forwardsClose() async throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.base.simulateClose(code: 1006, reason: "gone")
        h.base.simulateClose(code: 1006, reason: "gone")
        #expect(h.recorder.closes == [TransportClose(code: 1006, reason: "gone")])
        await h.clock.advance(by: .seconds(3))
        await settle()
        #expect(h.base.sentText.count == 1)
    }

    @Test("close passes the code and reason through to the base transport")
    func closePassesThrough() throws {
        let h = try Harness()
        h.channel.close(code: 1000, reason: "Client closed")
        #expect(h.base.closedWith == TransportClose(code: 1000, reason: "Client closed"))
    }

    @Test("rejects a malformed daemon key at construction")
    func rejectsBadKey() {
        let base = FakeTransport(request: TransportRequest(url: URL(string: "wss://relay.test/ws")!))
        #expect(throws: E2EEBoxError.invalidPublicKeyLength(3)) {
            try E2EEChannel(base: base, daemonPublicKeyB64: "AAAA", clock: TestClock())
        }
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter E2EEChannelTests`
Expected: `error: cannot find 'E2EEChannel' in scope`.

- [ ] **Step 4: Write the channel**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/E2EEChannel.swift`:

```swift
import Foundation

/// The client side of `@getpaseo/relay` 0.4.0 `encrypted-channel.ts`, as a
/// transport that wraps another transport.
///
/// Handshake: on the base socket opening, generate a fresh key pair, derive
/// the shared key from the daemon public key in the offer, and send a
/// plaintext `e2ee_hello` carrying our public key. Repeat it every second
/// until `e2ee_ready` arrives (the relay accepts our socket before the daemon
/// has attached, so the first hellos can go unanswered). The ready message
/// carries no key: the daemon is authenticated by the offer, not the wire.
///
/// After that every frame is `E2EEBox` output. Text plaintext travels as
/// base64 in a text frame; binary plaintext as a binary frame when the daemon
/// advertised `binaryCiphertext`, else base64 too. Frames sent while still
/// handshaking are queued (newest 200 kept) and flushed on open.
///
/// A plaintext JSON frame after the handshake that is not a stray hello or
/// ready means the peer is not encrypting; that is fatal (close 1011) so the
/// session reconnects and re-handshakes rather than parsing someone else's
/// traffic.
@MainActor
public final class E2EEChannel: DaemonTransport {
    public static let handshakeRetryInterval: Duration = .seconds(1)
    public static let maxPendingSends = 200
    public static let fatalCloseCode = 1011

    private enum State { case idle, handshaking, open, closed }

    private struct HandshakeMessage: Decodable {
        struct Capabilities: Decodable { var binaryCiphertext: Bool? }
        var type: String
        var key: String?
        var capabilities: Capabilities?
    }

    private struct HelloMessage: Encodable {
        struct Capabilities: Encodable { let binaryCiphertext = true }
        let type = "e2ee_hello"
        let key: String
        let capabilities = Capabilities()
    }

    public var onOpen: (() -> Void)?
    public var onFrame: ((TransportFrame) -> Void)?
    public var onClose: ((TransportClose) -> Void)?
    public var onError: ((String) -> Void)?

    private let base: any DaemonTransport
    private let daemonPublicKey: [UInt8]
    private let clock: any Clock<Duration>
    private var state: State = .idle
    private var sharedKey: E2EESharedKey?
    private var helloText = ""
    private var binaryCiphertext = false
    private var pendingSends: [TransportFrame] = []
    private var retryTask: Task<Void, Never>?
    private var closeForwarded = false

    public init(base: any DaemonTransport, daemonPublicKeyB64: String, clock: any Clock<Duration>) throws {
        self.base = base
        self.daemonPublicKey = try E2EEBox.importPublicKey(base64: daemonPublicKeyB64)
        self.clock = clock
    }

    /// True once `e2ee_ready` has been received. Exposed for the probe CLI and tests.
    public var isOpen: Bool { state == .open }

    public func connect() {
        base.onOpen = { [weak self] in self?.handleBaseOpen() }
        base.onFrame = { [weak self] frame in self?.handleBaseFrame(frame) }
        base.onClose = { [weak self] close in self?.handleBaseClose(close) }
        base.onError = { [weak self] message in self?.onError?(message) }
        state = .idle
        base.connect()
    }

    public func send(_ frame: TransportFrame) {
        switch state {
        case .idle, .handshaking:
            if pendingSends.count >= Self.maxPendingSends { pendingSends.removeFirst() }
            pendingSends.append(frame)
        case .open:
            guard let sharedKey else { return }
            let plaintext: [UInt8]
            let isBinary: Bool
            switch frame {
            case .text(let text):
                plaintext = Array(text.utf8)
                isBinary = false
            case .binary(let bytes):
                plaintext = bytes
                isBinary = true
            }
            let cipher: [UInt8]
            do {
                cipher = try E2EEBox.encrypt(plaintext, with: sharedKey)
            } catch {
                fail("Encryption failed")
                return
            }
            if binaryCiphertext && isBinary {
                base.send(.binary(cipher))
            } else {
                base.send(.text(Data(cipher).base64EncodedString()))
            }
        case .closed:
            onError?("Channel not open")
        }
    }

    public func close(code: Int, reason: String) {
        retryTask?.cancel()
        retryTask = nil
        state = .closed
        base.close(code: code, reason: reason)
    }

    // MARK: - Base transport events

    private func handleBaseOpen() {
        guard state == .idle else { return }
        let pair = E2EEBox.generateKeyPair()
        do {
            sharedKey = try E2EEBox.deriveSharedKey(ourSecretKey: pair.secretKey, peerPublicKey: daemonPublicKey)
        } catch {
            fail("E2EE key derivation failed: \(error)")
            return
        }
        let hello = HelloMessage(key: E2EEBox.exportPublicKey(pair.publicKey))
        guard let data = try? JSONEncoder().encode(hello) else {
            fail("Could not encode e2ee_hello")
            return
        }
        helloText = String(decoding: data, as: UTF8.self)
        state = .handshaking
        base.send(.text(helloText))
        retryTask = Task { [weak self] in
            while true {
                guard let self, self.state == .handshaking else { return }
                do {
                    try await self.clock.sleep(for: Self.handshakeRetryInterval)
                } catch {
                    return
                }
                guard self.state == .handshaking else { return }
                self.base.send(.text(self.helloText))
            }
        }
    }

    private func handleBaseFrame(_ frame: TransportFrame) {
        switch state {
        case .handshaking:
            guard case .text(let text) = frame,
                  let message = Self.parseHandshake(text),
                  message.type == "e2ee_ready" else { return }
            binaryCiphertext = message.capabilities?.binaryCiphertext == true
            state = .open
            retryTask?.cancel()
            retryTask = nil
            onOpen?()
            let pending = pendingSends
            pendingSends = []
            for item in pending { send(item) }
        case .open:
            handleOpenFrame(frame)
        case .idle, .closed:
            return
        }
    }

    private func handleOpenFrame(_ frame: TransportFrame) {
        guard let sharedKey else { return }
        let cipher: [UInt8]
        let wasBinary: Bool
        switch frame {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                if let message = Self.parseHandshake(trimmed),
                   message.type == "e2ee_hello" || message.type == "e2ee_ready" {
                    return
                }
                fail("Received plaintext frame on encrypted channel")
                return
            }
            guard let data = Data(base64Encoded: trimmed) else {
                fail("Ciphertext frame was not base64")
                return
            }
            cipher = [UInt8](data)
            wasBinary = false
        case .binary(let bytes):
            cipher = bytes
            wasBinary = true
        }
        let plaintext: [UInt8]
        do {
            plaintext = try E2EEBox.decrypt(cipher, with: sharedKey)
        } catch {
            fail("Decryption failed")
            return
        }
        if wasBinary {
            onFrame?(.binary(plaintext))
        } else {
            guard let text = String(bytes: plaintext, encoding: .utf8) else {
                fail("Decrypted text frame was not UTF-8")
                return
            }
            onFrame?(.text(text))
        }
    }

    private func handleBaseClose(_ close: TransportClose) {
        retryTask?.cancel()
        retryTask = nil
        state = .closed
        guard !closeForwarded else { return }
        closeForwarded = true
        onClose?(close)
    }

    private func fail(_ message: String) {
        onError?(message)
        retryTask?.cancel()
        retryTask = nil
        state = .closed
        base.close(code: Self.fatalCloseCode, reason: message)
    }

    private static func parseHandshake(_ text: String) -> HandshakeMessage? {
        try? JSONDecoder().decode(HandshakeMessage.self, from: Data(text.utf8))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 34 tests in 5 suites passed`.

- [ ] **Step 6: Mutate to prove the fatal rule bites**

In `handleOpenFrame`, temporarily replace `fail("Received plaintext frame on encrypted channel")` with `return`. Run `swift test --package-path PaseoIconPackage --filter E2EEChannelTests`.
Expected: `a plaintext frame after open is fatal` fails. Revert and confirm green.

- [ ] **Step 7: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): relay E2EE channel as a transport over a transport

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Wire messages and the daemon session

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonMessages.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonSession.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/DaemonWire.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/DaemonSessionTests.swift`

**Interfaces:**
- Consumes `DaemonTransport`, `TransportFactory`, `E2EEChannel` from Task 4.
- Produces `DaemonSessionConfig(url:clientId:appVersion:)` with the tunables in the spec's table, `ConnectionState` (`.idle`, `.connecting(attempt:)`, `.connected`, `.disconnected(reason:)`, `.disposed`), `DaemonSessionError`, and `DaemonSession(config:transportFactory:clock:)` with `connect()`, `close()`, `connectionState`, `lastServerInfo`, `lastError`, `subscribeConnectionStatus(_:) -> () -> Void`, `onAgentUpdate(_:) -> () -> Void`, `onWorkspaceUpdate(_:) -> () -> Void`, `fetchAgents(_:) async throws -> FetchAgentsResponsePayload`, `fetchWorkspaces(_:) async throws -> FetchWorkspacesResponsePayload`, `static defaultCapabilities`.
- Produces the models `ServerInfo`, `WorkspaceStateBucket`, `DiffStat`, `WorkspaceDescriptor` (with `bucket`), `AgentSnapshot`, `AgentUpdate`, `WorkspaceUpdate`, `PageInfo`, `FetchAgentsResponsePayload` (`entries[].agent`, `pageInfo.hasMore`), `FetchWorkspacesResponsePayload`, `SortKey`, `FetchAgentsOptions(sort:pageLimit:subscribe:)`, `FetchWorkspacesOptions`.
- Test support produces `DaemonWire` transcripts: `serverInfo(serverId:hostname:)`, `pong`, `fetchAgentsResponse(requestId:agents:hasMore:)`, `fetchWorkspacesResponse(requestId:workspaces:hasMore:)`, `rpcError(requestId:error:)`, `agentUpsert(id:status:)`, `agentRemove(id:)`, `workspaceUpsert(id:status:)`, `workspaceRemove(id:)`.

- [ ] **Step 1: Write the wire transcripts and the failing session test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/DaemonWire.swift`:

```swift
import Foundation

/// The wire shapes a 0.4.0 daemon sends, as strings, so tests read like transcripts.
enum DaemonWire {
    static func serverInfo(serverId: String, hostname: String? = "studio") -> String {
        let hostnameJSON = hostname.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"\#(serverId)","hostname":\#(hostnameJSON)}}}"#
    }

    static let pong = #"{"type":"pong"}"#

    static func fetchAgentsResponse(requestId: String, agents: [String] = [], hasMore: Bool = false) -> String {
        let entries = agents.map { #"{"agent":\#(agent(id: $0))}"# }.joined(separator: ",")
        return #"{"type":"session","message":{"type":"fetch_agents_response","payload":{"requestId":"\#(requestId)","entries":[\#(entries)],"pageInfo":{"nextCursor":null,"prevCursor":null,"hasMore":\#(hasMore)}}}}"#
    }

    static func fetchWorkspacesResponse(requestId: String, workspaces: [String] = [], hasMore: Bool = false) -> String {
        let entries = workspaces.map { workspace(id: $0) }.joined(separator: ",")
        return #"{"type":"session","message":{"type":"fetch_workspaces_response","payload":{"requestId":"\#(requestId)","entries":[\#(entries)],"pageInfo":{"nextCursor":null,"prevCursor":null,"hasMore":\#(hasMore)}}}}"#
    }

    static func rpcError(requestId: String, error: String) -> String {
        #"{"type":"session","message":{"type":"rpc_error","payload":{"requestId":"\#(requestId)","error":"\#(error)"}}}"#
    }

    static func agent(id: String, workspaceId: String = "ws-1", status: String = "running") -> String {
        #"{"id":"\#(id)","provider":"claude","cwd":"/tmp","workspaceId":"\#(workspaceId)","model":null,"createdAt":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z","lastUserMessageAt":null,"status":"\#(status)","capabilities":{},"currentModeId":null,"availableModes":[],"pendingPermissions":[],"persistence":null,"title":"Agent \#(id)","labels":{}}"#
    }

    static func workspace(id: String, status: String = "running", name: String = "feature") -> String {
        #"{"id":"\#(id)","projectId":"p1","projectDisplayName":"paseo-menubar","projectRootPath":"/tmp/p1","projectKind":"git","workspaceKind":"worktree","name":"\#(name)","status":"\#(status)","archivingAt":null,"activityAt":null,"diffStat":{"additions":3,"deletions":1},"scripts":[],"gitRuntime":{},"githubRuntime":{}}"#
    }

    static func agentUpsert(id: String, status: String = "running") -> String {
        #"{"type":"session","message":{"type":"agent_update","payload":{"kind":"upsert","agent":\#(agent(id: id, status: status))}}}"#
    }

    static func agentRemove(id: String) -> String {
        #"{"type":"session","message":{"type":"agent_update","payload":{"kind":"remove","agentId":"\#(id)"}}}"#
    }

    static func workspaceUpsert(id: String, status: String = "needs_input") -> String {
        #"{"type":"session","message":{"type":"workspace_update","payload":{"kind":"upsert","workspace":\#(workspace(id: id, status: status))}}}"#
    }

    static func workspaceRemove(id: String) -> String {
        #"{"type":"session","message":{"type":"workspace_update","payload":{"kind":"remove","id":"\#(id)"}}}"#
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/DaemonSessionTests.swift`:

```swift
import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct DaemonSessionTests {
    @MainActor
    struct Harness {
        let clock = TestClock()
        let factory = FakeTransportFactory()
        let session: DaemonSession
        private let stateLog = StateLog()

        @MainActor
        final class StateLog {
            var states: [ConnectionState] = []
        }

        init(password: String? = nil, e2eeKey: String? = nil, configure: (inout DaemonSessionConfig) -> Void = { _ in }) {
            var config = DaemonSessionConfig(
                url: URL(string: "ws://127.0.0.1:6767/ws")!,
                clientId: "paseo-menubar-test",
                appVersion: "0.4.0"
            )
            config.password = password
            config.e2eeDaemonPublicKeyB64 = e2eeKey
            configure(&config)
            session = DaemonSession(config: config, transportFactory: factory.make, clock: clock)
            _ = session.subscribeConnectionStatus { [stateLog] state in stateLog.states.append(state) }
        }

        var states: [ConnectionState] { stateLog.states }
        var transport: FakeTransport { factory.last! }

        /// Open the socket and deliver server_info, the two steps to `connected`.
        func connectFully(serverId: String = "srv-1") {
            session.connect()
            transport.simulateOpen()
            transport.simulateText(DaemonWire.serverInfo(serverId: serverId))
        }

        /// The session message of the last frame the client sent, decoded.
        func lastSentSessionMessage() throws -> [String: Any] {
            let envelope = try jsonObject(try #require(transport.sentText.last))
            #expect(envelope["type"] as? String == "session")
            return try #require(envelope["message"] as? [String: Any])
        }
    }

    @Test("dials with the password as bearer header and subprotocol")
    func passwordOnTheWire() {
        let h = Harness(password: " s3cret ")
        h.session.connect()
        #expect(h.transport.request.headers == ["Authorization": "Bearer s3cret"])
        #expect(h.transport.request.subprotocols == ["paseo.bearer.s3cret"])
        #expect(h.transport.connectCalls == 1)
    }

    @Test("dials without auth when there is no password")
    func noPassword() {
        let h = Harness()
        h.session.connect()
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
    }

    @Test("sends hello on open with protocolVersion 1 and the capability set")
    func helloOnOpen() throws {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        let hello = try jsonObject(try #require(h.transport.sentText.first))
        #expect(hello["type"] as? String == "hello")
        #expect(hello["clientId"] as? String == "paseo-menubar-test")
        #expect(hello["clientType"] as? String == "cli")
        #expect(hello["protocolVersion"] as? Int == 1)
        #expect(hello["appVersion"] as? String == "0.4.0")
        let capabilities = try #require(hello["capabilities"] as? [String: Bool])
        #expect(capabilities == DaemonSession.defaultCapabilities)
        #expect(capabilities["selective_agent_timeline"] == true)
    }

    @Test("reports connected only once server_info arrives")
    func connectedOnServerInfo() {
        let h = Harness()
        h.session.connect()
        #expect(h.states == [.idle, .connecting(attempt: 0)])
        h.transport.simulateOpen()
        #expect(h.session.connectionState == .connecting(attempt: 0))
        h.transport.simulateText(DaemonWire.serverInfo(serverId: " srv-1 ", hostname: "studio"))
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastServerInfo == ServerInfo(serverId: "srv-1", hostname: "studio"))
    }

    @Test("a non-string hostname reads as nil")
    func hostnameLenient() {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        h.transport.simulateText(#"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"s","hostname":42}}}"#)
        #expect(h.session.lastServerInfo == ServerInfo(serverId: "s", hostname: nil))
    }

    @Test("times out a connect with no server_info, then backs off exponentially")
    func connectTimeoutAndBackoff() async {
        let h = Harness()
        h.session.connect()
        h.transport.simulateOpen()
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .disconnected(reason: "Connection timed out"))
        #expect(h.factory.transports[0].closedWith?.code == 1001)
        await h.clock.advance(by: .milliseconds(1499))
        await settle()
        #expect(h.factory.transports.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await settle()
        #expect(h.factory.transports.count == 2)
        #expect(h.session.connectionState == .connecting(attempt: 1))
        await h.clock.advance(by: .seconds(15))
        await settle()
        await h.clock.advance(by: .seconds(3))
        await settle()
        #expect(h.factory.transports.count == 3, "second delay is 1.5s * 2")
    }

    @Test("a successful connect resets the backoff")
    func backoffResets() async {
        let h = Harness()
        h.session.connect()
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.factory.transports.count == 2)
        h.transport.simulateOpen()
        h.transport.simulateText(DaemonWire.serverInfo(serverId: "srv-1"))
        #expect(h.session.connectionState == .connected)
        h.transport.simulateClose(code: 1006, reason: "")
        #expect(h.session.connectionState == .disconnected(reason: "Transport closed (code 1006)"))
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.factory.transports.count == 3, "back to the base delay")
    }

    @Test("the close reason becomes the disconnected reason")
    func closeReason() {
        let h = Harness()
        h.connectFully()
        h.transport.simulateClose(code: 4401, reason: "Incorrect password")
        #expect(h.session.connectionState == .disconnected(reason: "Incorrect password"))
    }

    @Test("correlates a fetch response by requestId and decodes it")
    func fetchAgents() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(
                sort: [SortKey(key: "status_priority", direction: "asc")],
                pageLimit: 200,
                subscribe: true
            ))
        }
        await settle()
        let request = try h.lastSentSessionMessage()
        #expect(request["type"] as? String == "fetch_agents_request")
        let requestId = try #require(request["requestId"] as? String)
        #expect((request["page"] as? [String: Any])?["limit"] as? Int == 200)
        #expect((request["subscribe"] as? [String: Any])?.isEmpty == true)
        #expect((request["sort"] as? [[String: String]]) == [["key": "status_priority", "direction": "asc"]])
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: "someone-else", agents: ["x"]))
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: requestId, agents: ["a1", "a2"], hasMore: true))
        let response = try await task.value
        #expect(response.entries.map(\.agent.id) == ["a1", "a2"])
        #expect(response.pageInfo.hasMore)
        #expect(response.entries[0].agent.workspaceId == "ws-1")
    }

    @Test("omits subscribe when not asked for")
    func fetchWithoutSubscribe() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchWorkspaces(FetchWorkspacesOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        let request = try h.lastSentSessionMessage()
        #expect(request["type"] as? String == "fetch_workspaces_request")
        #expect(request["subscribe"] == nil)
        let requestId = try #require(request["requestId"] as? String)
        h.transport.simulateText(DaemonWire.fetchWorkspacesResponse(requestId: requestId, workspaces: ["w1"]))
        let response = try await task.value
        #expect(response.entries.map(\.id) == ["w1"])
        #expect(response.entries[0].bucket == .running)
        #expect(response.entries[0].diffStat == DiffStat(additions: 3, deletions: 1))
    }

    @Test("a fetch fails with a timeout when nothing answers")
    func fetchTimeout() async throws {
        // Shorter than the ping interval: past 35 seconds of silence the
        // liveness check reconnects first and fails the request with
        // connectionLost, which is the right outcome but not this test's.
        let h = Harness(configure: { $0.requestTimeout = .seconds(5) })
        h.connectFully()
        let task = Task {
            try await h.session.fetchWorkspaces(FetchWorkspacesOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        await h.clock.advance(by: .seconds(5))
        await settle()
        await #expect(throws: DaemonSessionError.timeout("fetch_workspaces_response")) { try await task.value }
    }

    @Test("rpc_error rejects the matching request")
    func rpcError() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        let requestId = try #require(try h.lastSentSessionMessage()["requestId"] as? String)
        h.transport.simulateText(DaemonWire.rpcError(requestId: requestId, error: "boom"))
        await #expect(throws: DaemonSessionError.rpcError("boom")) { try await task.value }
    }

    @Test("a disconnect fails requests in flight")
    func disconnectFailsRequests() async throws {
        let h = Harness()
        h.connectFully()
        let task = Task {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
        await settle()
        h.transport.simulateClose(code: 1006, reason: "gone")
        await #expect(throws: DaemonSessionError.connectionLost("gone")) { try await task.value }
    }

    @Test("a fetch before connected fails immediately")
    func fetchBeforeConnected() async {
        let h = Harness()
        h.session.connect()
        await #expect(throws: DaemonSessionError.notConnected) {
            try await h.session.fetchAgents(FetchAgentsOptions(sort: [], pageLimit: 10, subscribe: false))
        }
    }

    @Test("pings every 10 seconds and reconnects after two unanswered pings")
    func livenessReconnect() async {
        let h = Harness()
        h.connectFully()
        h.transport.clearSent()
        await settle()
        await h.clock.advance(by: .seconds(10))
        await settle()
        #expect(h.transport.sentText == [#"{"type":"ping"}"#])
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected, "one miss is tolerated")
        await h.clock.advance(by: .seconds(10))
        await settle()
        #expect(h.transport.sentText.count == 2)
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .disconnected(reason: "Liveness check timed out"))
        #expect(h.factory.transports[0].closedWith?.code == 1001)
    }

    @Test("a pong answers the ping and resets the failure count")
    func pongKeepsAlive() async {
        let h = Harness()
        h.connectFully()
        await settle()
        await h.clock.advance(by: .seconds(10))
        await settle()
        h.transport.simulateText(DaemonWire.pong)
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected)
        await h.clock.advance(by: .seconds(10))
        await settle()
        await h.clock.advance(by: .seconds(15))
        await settle()
        #expect(h.session.connectionState == .connected, "a single miss after a pong is still one miss")
    }

    @Test("dispatches agent and workspace updates to listeners")
    func updates() {
        let h = Harness()
        h.connectFully()
        var agentUpdates: [AgentUpdate] = []
        var workspaceUpdates: [WorkspaceUpdate] = []
        _ = h.session.onAgentUpdate { agentUpdates.append($0) }
        _ = h.session.onWorkspaceUpdate { workspaceUpdates.append($0) }
        h.transport.simulateText(DaemonWire.agentUpsert(id: "a1", status: "idle"))
        h.transport.simulateText(DaemonWire.agentRemove(id: "a1"))
        h.transport.simulateText(DaemonWire.workspaceUpsert(id: "w1", status: "needs_input"))
        h.transport.simulateText(DaemonWire.workspaceRemove(id: "w1"))
        #expect(agentUpdates.count == 2)
        if case .upsert(let agent) = agentUpdates[0] {
            #expect(agent.id == "a1")
            #expect(agent.status == "idle")
        } else {
            Issue.record("expected upsert")
        }
        #expect(agentUpdates[1] == .remove(agentId: "a1"))
        #expect(workspaceUpdates.count == 2)
        if case .upsert(let workspace) = workspaceUpdates[0] {
            #expect(workspace.id == "w1")
            #expect(workspace.bucket == .needsInput)
        } else {
            Issue.record("expected upsert")
        }
        #expect(workspaceUpdates[1] == .remove(id: "w1"))
    }

    @Test("an unknown bucket decodes with bucket nil rather than failing")
    func unknownBucket() {
        let h = Harness()
        h.connectFully()
        var workspaceUpdates: [WorkspaceUpdate] = []
        _ = h.session.onWorkspaceUpdate { workspaceUpdates.append($0) }
        h.transport.simulateText(DaemonWire.workspaceUpsert(id: "w1", status: "brand_new_bucket"))
        guard case .upsert(let workspace)? = workspaceUpdates.first else {
            Issue.record("expected upsert")
            return
        }
        #expect(workspace.status == "brand_new_bucket")
        #expect(workspace.bucket == nil)
    }

    @Test("unknown and malformed messages are ignored, not fatal")
    func ignoresUnknown() {
        let h = Harness()
        h.connectFully()
        h.transport.simulateText(#"{"type":"session","message":{"type":"agent_stream","payload":{}}}"#)
        h.transport.simulateText(#"{"type":"session","message":{"type":"agent_update","payload":{"kind":"upsert"}}}"#)
        h.transport.simulateText("not json")
        h.transport.simulateBinary([1, 2, 3])
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastError?.hasPrefix("Message validation failed") == true)
    }

    @Test("close disposes the session and never reconnects")
    func closeDisposes() async {
        let h = Harness()
        h.connectFully()
        h.session.close()
        #expect(h.session.connectionState == .disposed)
        #expect(h.transport.closedWith == TransportClose(code: 1000, reason: "Client closed"))
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
        #expect(h.states.last == .disposed)
    }

    @Test("wraps the transport in an E2EE channel for relay hosts")
    func relayWrapsChannel() throws {
        let daemon = E2EEBox.generateKeyPair()
        let h = Harness(e2eeKey: E2EEBox.exportPublicKey(daemon.publicKey))
        h.session.connect()
        h.transport.simulateOpen()
        let first = try jsonObject(try #require(h.transport.sentText.first))
        #expect(first["type"] as? String == "e2ee_hello")
        #expect(h.session.connectionState == .connecting(attempt: 0))
        let clientKey = try E2EEBox.importPublicKey(base64: try #require(first["key"] as? String))
        let shared = try E2EEBox.deriveSharedKey(ourSecretKey: daemon.secretKey, peerPublicKey: clientKey)
        h.transport.simulateText(#"{"type":"e2ee_ready","capabilities":{"binaryCiphertext":true}}"#)
        let encryptedHello = try #require(h.transport.sentText.last)
        let hello = try jsonObject(String(decoding: try E2EEBox.decrypt([UInt8](try #require(Data(base64Encoded: encryptedHello))), with: shared), as: UTF8.self))
        #expect(hello["type"] as? String == "hello")
        let serverInfo = Data(try E2EEBox.encrypt(Array(DaemonWire.serverInfo(serverId: "relayed").utf8), with: shared)).base64EncodedString()
        h.transport.simulateText(serverInfo)
        #expect(h.session.connectionState == .connected)
        #expect(h.session.lastServerInfo?.serverId == "relayed")
    }

    @Test("an invalid daemon key gives up without retrying")
    func invalidKeyGivesUp() async {
        let h = Harness(e2eeKey: "AAAA")
        h.session.connect()
        #expect(h.session.connectionState == .disconnected(reason: "Invalid daemon public key"))
        #expect(h.transport.connectCalls == 0)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter DaemonSessionTests`
Expected: `error: cannot find 'DaemonSessionConfig' in scope`.

- [ ] **Step 3: Write the messages**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonMessages.swift`:

```swift
import Foundation

// The slice of `@getpaseo/protocol` 0.4.0 `messages.ts` this app speaks.
// Decoding is lenient by design: unknown fields are ignored and enum-like
// strings are kept as strings, because the protocol contract is additive and
// a new daemon must not make the tray fail to parse.

public struct ServerInfo: Equatable, Sendable {
    public let serverId: String
    /// Non-string values become nil, as upstream's `ServerInfoHostnameSchema` does.
    public let hostname: String?

    public init(serverId: String, hostname: String?) {
        self.serverId = serverId
        self.hostname = hostname
    }
}

/// `WorkspaceStateBucketSchema` upstream. The daemon computes the bucket; the
/// tray renders it and never derives it.
public enum WorkspaceStateBucket: String, Codable, CaseIterable, Sendable {
    case needsInput = "needs_input"
    case failed
    case running
    case attention
    case done
}

public struct DiffStat: Codable, Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
}

public struct WorkspaceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let projectDisplayName: String
    public let name: String
    /// The raw bucket string. `bucket` is nil for a value this build does not know.
    public let status: String
    public let archivingAt: String?
    public let activityAt: String?
    public let diffStat: DiffStat?

    public var bucket: WorkspaceStateBucket? { WorkspaceStateBucket(rawValue: status) }
}

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let workspaceId: String?
    public let status: String
    public let title: String?
    public let updatedAt: String
    public let requiresAttention: Bool?
    public let attentionReason: String?
    public let archivedAt: String?
}

public enum AgentUpdate: Equatable, Sendable {
    case upsert(AgentSnapshot)
    case remove(agentId: String)
}

public enum WorkspaceUpdate: Equatable, Sendable {
    case upsert(WorkspaceDescriptor)
    case remove(id: String)
}

public struct PageInfo: Codable, Equatable, Sendable {
    public let hasMore: Bool
}

public struct FetchAgentsResponsePayload: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let agent: AgentSnapshot
    }

    public let requestId: String
    public let entries: [Entry]
    public let pageInfo: PageInfo
}

public struct FetchWorkspacesResponsePayload: Decodable, Equatable, Sendable {
    public let requestId: String
    public let entries: [WorkspaceDescriptor]
    public let pageInfo: PageInfo
}

public struct SortKey: Encodable, Equatable, Sendable {
    public let key: String
    public let direction: String

    public init(key: String, direction: String) {
        self.key = key
        self.direction = direction
    }
}

public struct FetchAgentsOptions: Equatable, Sendable {
    public var sort: [SortKey]
    public var pageLimit: Int
    public var subscribe: Bool

    public init(sort: [SortKey], pageLimit: Int, subscribe: Bool) {
        self.sort = sort
        self.pageLimit = pageLimit
        self.subscribe = subscribe
    }
}

public typealias FetchWorkspacesOptions = FetchAgentsOptions

// MARK: - Wire encoding

struct EmptyObject: Encodable {}

struct SessionEnvelope<Message: Encodable>: Encodable {
    let type = "session"
    let message: Message
}

struct HelloMessage: Encodable {
    let type = "hello"
    let clientId: String
    let clientType: String
    let protocolVersion: Int
    let appVersion: String
    let capabilities: [String: Bool]
}

struct FetchRequestMessage: Encodable {
    struct Page: Encodable { let limit: Int }
    let type: String
    let requestId: String
    let sort: [SortKey]
    let page: Page
    let subscribe: EmptyObject?
}

// MARK: - Wire decoding

enum InboundMessage: Equatable {
    case pong
    case serverInfo(ServerInfo)
    case agentUpdate(AgentUpdate)
    case workspaceUpdate(WorkspaceUpdate)
    /// A `*_response` session message; `payload` is its payload re-serialized for typed decoding.
    case response(requestId: String, type: String, payload: Data)
    case rpcError(requestId: String, error: String)
    case other(type: String)
}

enum InboundParseError: Error, Equatable {
    case notAnObject
    case missingType
    case malformed(String)
}

enum InboundParser {
    static func parse(_ text: String) throws -> InboundMessage {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw InboundParseError.notAnObject
        }
        guard let envelopeType = root["type"] as? String else { throw InboundParseError.missingType }
        if envelopeType == "pong" { return .pong }
        guard envelopeType == "session", let message = root["message"] as? [String: Any] else {
            return .other(type: envelopeType)
        }
        guard let type = message["type"] as? String else { throw InboundParseError.missingType }
        let payload = message["payload"] as? [String: Any] ?? [:]
        switch type {
        case "status":
            guard payload["status"] as? String == "server_info" else { return .other(type: "status") }
            guard let serverId = (payload["serverId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !serverId.isEmpty else {
                throw InboundParseError.malformed("server_info without serverId")
            }
            return .serverInfo(ServerInfo(serverId: serverId, hostname: payload["hostname"] as? String))
        case "agent_update":
            switch payload["kind"] as? String {
            case "upsert":
                guard let agent = payload["agent"] else { throw InboundParseError.malformed("agent upsert without agent") }
                return .agentUpdate(.upsert(try decode(AgentSnapshot.self, from: agent)))
            case "remove":
                guard let agentId = payload["agentId"] as? String else {
                    throw InboundParseError.malformed("agent remove without agentId")
                }
                return .agentUpdate(.remove(agentId: agentId))
            default:
                throw InboundParseError.malformed("agent_update kind")
            }
        case "workspace_update":
            switch payload["kind"] as? String {
            case "upsert":
                guard let workspace = payload["workspace"] else {
                    throw InboundParseError.malformed("workspace upsert without workspace")
                }
                return .workspaceUpdate(.upsert(try decode(WorkspaceDescriptor.self, from: workspace)))
            case "remove":
                // The removal field here is `id`; `agent_update`'s is `agentId`.
                guard let id = payload["id"] as? String else {
                    throw InboundParseError.malformed("workspace remove without id")
                }
                return .workspaceUpdate(.remove(id: id))
            default:
                throw InboundParseError.malformed("workspace_update kind")
            }
        case "rpc_error":
            guard let requestId = payload["requestId"] as? String else { return .other(type: type) }
            return .rpcError(requestId: requestId, error: payload["error"] as? String ?? "rpc_error")
        default:
            if type.hasSuffix("_response"), let requestId = payload["requestId"] as? String {
                let data = try JSONSerialization.data(withJSONObject: payload)
                return .response(requestId: requestId, type: type, payload: data)
            }
            return .other(type: type)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
```

- [ ] **Step 4: Write the session**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonSession.swift`:

```swift
import Foundation

public struct DaemonSessionConfig: Sendable {
    public var url: URL
    public var clientId: String
    public var clientType: String = "cli"
    public var appVersion: String
    public var password: String? = nil
    /// Set for relay hosts. Wraps the transport in `E2EEChannel`.
    public var e2eeDaemonPublicKeyB64: String? = nil
    public var capabilities: [String: Bool] = DaemonSession.defaultCapabilities
    public var connectTimeout: Duration = .seconds(15)
    public var reconnectBaseDelay: Duration = .milliseconds(1500)
    public var reconnectMaxDelay: Duration = .seconds(30)
    public var pingInterval: Duration = .seconds(10)
    public var pingTimeout: Duration = .seconds(15)
    public var livenessFailureThreshold: Int = 2
    public var requestTimeout: Duration = .seconds(60)

    public init(url: URL, clientId: String, appVersion: String) {
        self.url = url
        self.clientId = clientId
        self.appVersion = appVersion
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected
    case disconnected(reason: String?)
    case disposed
}

public enum DaemonSessionError: Error, Equatable {
    case notConnected
    case connectionLost(String?)
    case timeout(String)
    case rpcError(String)
    case disposed
}

/// The slice of `@getpaseo/client` 0.4.0 `DaemonClient` this app needs, on
/// the wire rather than through the SDK:
///
/// - connect, send `hello`, and report `connected` only once `server_info`
///   arrives (the relay accepts a socket even when the daemon is offline);
/// - a connect timeout, then exponential backoff between attempts;
/// - a `ping` every `pingInterval` once connected, a reconnect after
///   `livenessFailureThreshold` unanswered pings (relay sockets go half-open);
/// - `fetch_*_request` correlated by `requestId`, with a timeout;
/// - the `agent_update` and `workspace_update` streams.
///
/// Every callback fires on the main actor. Timers use the injected clock so
/// tests drive them with `TestClock`.
@MainActor
public final class DaemonSession {
    /// The set the 0.4.0 client advertises, plus `selective_agent_timeline`:
    /// without it the daemon streams every agent's timeline (`agent_stream`)
    /// to this client, which never views a timeline. With it, only
    /// `agent_attention_required` events arrive, which matters through a relay.
    nonisolated public static let defaultCapabilities: [String: Bool] = [
        "custom_mode_icons": true,
        "reasoning_merge_enum": true,
        "terminal_reflowable_snapshot": true,
        "provider_subagents": true,
        "project_updates": true,
        "compact_provider_snapshots": true,
        "selective_agent_timeline": true,
    ]

    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var lastServerInfo: ServerInfo?
    public private(set) var lastError: String?

    private struct PendingRequest {
        let expectedType: String
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    @MainActor
    private final class PingProbe {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func settle(_ ok: Bool) {
            guard result == nil else { return }
            result = ok
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: ok)
            }
        }

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private let config: DaemonSessionConfig
    private let transportFactory: TransportFactory
    private let clock: any Clock<Duration>
    private var transport: (any DaemonTransport)?
    private var shouldReconnect = true
    private var reconnectAttempt = 0
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var pingProbe: PingProbe?
    private var consecutiveLivenessFailures = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var statusListeners: [UUID: (ConnectionState) -> Void] = [:]
    private var agentListeners: [UUID: (AgentUpdate) -> Void] = [:]
    private var workspaceListeners: [UUID: (WorkspaceUpdate) -> Void] = [:]

    public init(config: DaemonSessionConfig, transportFactory: @escaping TransportFactory, clock: any Clock<Duration>) {
        self.config = config
        self.transportFactory = transportFactory
        self.clock = clock
    }

    // MARK: - Lifecycle

    public func connect() {
        guard connectionState != .disposed else { return }
        shouldReconnect = true
        attemptConnect()
    }

    /// Ends the session for good: no reconnect, pending requests fail with
    /// `.disposed`, listeners see `.disposed` once.
    public func close() {
        guard connectionState != .disposed else { return }
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopLiveness()
        failPendingRequests(DaemonSessionError.disposed)
        disposeTransport(code: 1000, reason: "Client closed")
        setState(.disposed)
    }

    // MARK: - Subscriptions

    /// Fires once immediately with the current state, then on every transition.
    public func subscribeConnectionStatus(_ listener: @escaping (ConnectionState) -> Void) -> () -> Void {
        let id = UUID()
        statusListeners[id] = listener
        listener(connectionState)
        return { [weak self] in self?.statusListeners[id] = nil }
    }

    public func onAgentUpdate(_ listener: @escaping (AgentUpdate) -> Void) -> () -> Void {
        let id = UUID()
        agentListeners[id] = listener
        return { [weak self] in self?.agentListeners[id] = nil }
    }

    public func onWorkspaceUpdate(_ listener: @escaping (WorkspaceUpdate) -> Void) -> () -> Void {
        let id = UUID()
        workspaceListeners[id] = listener
        return { [weak self] in self?.workspaceListeners[id] = nil }
    }

    // MARK: - Requests

    public func fetchAgents(_ options: FetchAgentsOptions) async throws -> FetchAgentsResponsePayload {
        let requestId = Self.makeRequestId()
        let message = FetchRequestMessage(
            type: "fetch_agents_request",
            requestId: requestId,
            sort: options.sort,
            page: .init(limit: options.pageLimit),
            subscribe: options.subscribe ? EmptyObject() : nil
        )
        let payload = try await sendRequest(message, requestId: requestId, expectedType: "fetch_agents_response")
        return try JSONDecoder().decode(FetchAgentsResponsePayload.self, from: payload)
    }

    public func fetchWorkspaces(_ options: FetchWorkspacesOptions) async throws -> FetchWorkspacesResponsePayload {
        let requestId = Self.makeRequestId()
        let message = FetchRequestMessage(
            type: "fetch_workspaces_request",
            requestId: requestId,
            sort: options.sort,
            page: .init(limit: options.pageLimit),
            subscribe: options.subscribe ? EmptyObject() : nil
        )
        let payload = try await sendRequest(message, requestId: requestId, expectedType: "fetch_workspaces_response")
        return try JSONDecoder().decode(FetchWorkspacesResponsePayload.self, from: payload)
    }

    // MARK: - Connecting

    private func attemptConnect() {
        guard connectionState != .disposed, shouldReconnect else { return }
        if case .connecting = connectionState { return }

        var headers: [String: String] = [:]
        var subprotocols: [String] = []
        if let password = config.password?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            headers["Authorization"] = "Bearer \(password)"
            subprotocols = ["paseo.bearer.\(password)"]
        }

        disposeTransport(code: 1001, reason: "Reconnecting")
        let base = transportFactory(TransportRequest(url: config.url, headers: headers, subprotocols: subprotocols))
        let transport: any DaemonTransport
        if let key = config.e2eeDaemonPublicKeyB64 {
            do {
                transport = try E2EEChannel(base: base, daemonPublicKeyB64: key, clock: clock)
            } catch {
                // An offer with a malformed key can never connect; retrying it
                // behind backoff forever is the failure mode to avoid.
                shouldReconnect = false
                lastError = "Invalid daemon public key: \(error)"
                setState(.disconnected(reason: "Invalid daemon public key"))
                return
            }
        } else {
            transport = base
        }
        self.transport = transport
        lastServerInfo = nil
        setState(.connecting(attempt: reconnectAttempt))
        armConnectTimeout()

        transport.onOpen = { [weak self] in self?.handleTransportOpen() }
        transport.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        transport.onClose = { [weak self] close in self?.handleTransportClose(close) }
        transport.onError = { [weak self] message in self?.lastError = message }
        transport.connect()
    }

    private func armConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.config.connectTimeout)
            } catch {
                return
            }
            guard case .connecting = self.connectionState else { return }
            self.lastError = "Connection timed out"
            self.disposeTransport(code: 1001, reason: "Connection timed out")
            self.scheduleReconnect(reason: "Connection timed out")
        }
    }

    private func handleTransportOpen() {
        let hello = HelloMessage(
            clientId: config.clientId,
            clientType: config.clientType,
            protocolVersion: 1,
            appVersion: config.appVersion,
            capabilities: config.capabilities
        )
        guard let transport, let data = try? JSONEncoder().encode(hello) else {
            scheduleReconnect(reason: "Failed to send hello message")
            return
        }
        transport.send(.text(String(decoding: data, as: UTF8.self)))
    }

    private func handleTransportClose(_ close: TransportClose) {
        let reason = close.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let described = reason.isEmpty ? "Transport closed (code \(close.code))" : reason
        lastError = described
        scheduleReconnect(reason: described)
    }

    private func handleFrame(_ frame: TransportFrame) {
        // Binary frames carry terminal and file-transfer data this client never asks for.
        guard case .text(let text) = frame else { return }
        let message: InboundMessage
        do {
            message = try InboundParser.parse(text)
        } catch {
            lastError = "Message validation failed: \(error)"
            return
        }
        consecutiveLivenessFailures = 0
        switch message {
        case .pong:
            pingProbe?.settle(true)
        case .serverInfo(let info):
            lastServerInfo = info
            if case .connecting = connectionState {
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
                reconnectAttempt = 0
                setState(.connected)
                startLiveness()
            }
        case .agentUpdate(let update):
            for listener in agentListeners.values { listener(update) }
        case .workspaceUpdate(let update):
            for listener in workspaceListeners.values { listener(update) }
        case .response(let requestId, let type, let payload):
            guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
            pending.timeoutTask.cancel()
            if pending.expectedType == type {
                pending.continuation.resume(returning: payload)
            } else {
                pending.continuation.resume(throwing: DaemonSessionError.rpcError("Unexpected response type \(type)"))
            }
        case .rpcError(let requestId, let error):
            rejectPending(requestId, DaemonSessionError.rpcError(error))
        case .other:
            return
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(reason: String?) {
        guard connectionState != .disposed else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        stopLiveness()
        failPendingRequests(DaemonSessionError.connectionLost(reason))
        disposeTransport(code: 1001, reason: "Reconnecting")
        setState(.disconnected(reason: reason))
        guard shouldReconnect else { return }
        armReconnectTimer()
    }

    private func armReconnectTimer() {
        let attempt = reconnectAttempt
        let factor = 1 << min(attempt, 20)
        let delay = min(config.reconnectBaseDelay * factor, config.reconnectMaxDelay)
        reconnectAttempt = attempt + 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: delay)
            } catch {
                return
            }
            guard self.shouldReconnect, self.connectionState != .disposed else { return }
            self.attemptConnect()
        }
    }

    // MARK: - Liveness

    private func startLiveness() {
        stopLiveness()
        consecutiveLivenessFailures = 0
        livenessTask = Task { [weak self] in
            while true {
                guard let self, self.connectionState == .connected else { return }
                do {
                    try await self.clock.sleep(for: self.config.pingInterval)
                } catch {
                    return
                }
                guard self.connectionState == .connected else { return }
                await self.runPingProbe()
            }
        }
    }

    private func stopLiveness() {
        livenessTask?.cancel()
        livenessTask = nil
        pingProbe?.settle(false)
        pingProbe = nil
    }

    private func runPingProbe() async {
        guard let transport else { return }
        let probe = PingProbe()
        pingProbe = probe
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.config.pingTimeout)
            } catch {
                return
            }
            probe.settle(false)
        }
        transport.send(.text(#"{"type":"ping"}"#))
        let answered = await probe.wait()
        timeoutTask.cancel()
        if pingProbe === probe { pingProbe = nil }
        guard connectionState == .connected else { return }
        if answered {
            consecutiveLivenessFailures = 0
            return
        }
        consecutiveLivenessFailures += 1
        guard consecutiveLivenessFailures >= config.livenessFailureThreshold else { return }
        consecutiveLivenessFailures = 0
        lastError = "Liveness check timed out"
        disposeTransport(code: 1001, reason: "Liveness timeout")
        scheduleReconnect(reason: "Liveness check timed out")
    }

    // MARK: - Requests plumbing

    private func sendRequest(_ message: some Encodable, requestId: String, expectedType: String) async throws -> Data {
        guard connectionState == .connected, let transport else { throw DaemonSessionError.notConnected }
        let data = try JSONEncoder().encode(SessionEnvelope(message: message))
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.clock.sleep(for: self.config.requestTimeout)
                } catch {
                    return
                }
                self.rejectPending(requestId, DaemonSessionError.timeout(expectedType))
            }
            pendingRequests[requestId] = PendingRequest(
                expectedType: expectedType,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            transport.send(.text(text))
        }
    }

    private func rejectPending(_ requestId: String, _ error: DaemonSessionError) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failPendingRequests(_ error: DaemonSessionError) {
        let pending = pendingRequests
        pendingRequests = [:]
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    private func disposeTransport(code: Int, reason: String) {
        guard let old = transport else { return }
        transport = nil
        old.onOpen = nil
        old.onFrame = nil
        old.onClose = nil
        old.onError = nil
        old.close(code: code, reason: reason)
    }

    private func setState(_ state: ConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        for listener in statusListeners.values { listener(state) }
    }

    private static func makeRequestId() -> String {
        UUID().uuidString.lowercased()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 56 tests in 6 suites passed`.

- [ ] **Step 6: Mutate to prove the liveness rule bites**

In `runPingProbe`, temporarily change `>= config.livenessFailureThreshold` to `>= 99`. Run `swift test --package-path PaseoIconPackage --filter DaemonSessionTests`.
Expected: `pings every 10 seconds and reconnects after two unanswered pings` fails. Revert and confirm green.

- [ ] **Step 7: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): daemon session on the 0.4.0 wire with timeouts, backoff, and liveness

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The host connection and its sink

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostSink.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostConnection.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/RecordingSink.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/HostConnectionTests.swift`

**Interfaces:**
- Consumes `DaemonSession` and the models from Task 5, `DaemonEndpoints` from Task 2, `HostEntry` from Task 1. `HostConnection.init` defaults its transport factory to `URLSessionWebSocketTransport`, which Task 7 creates; until then the tests inject `FakeTransportFactory.make` and the default is only referenced by the probe and app, which do not exist yet. **The package will not compile until Task 7 adds that type.** Do Tasks 6 and 7 back to back, or temporarily omit the default argument and add it in Task 7.
- Produces `HostStatus` (`connecting`, `connected`, `disconnected`, `unauthorized`, `invalid`), the `HostSink` protocol (`setHost`, `removeHost`, `setStatus`, `setServerId`, `setHostname`, `seedAgents`, `seedWorkspaces`, `applyAgentUpdate`, `applyWorkspaceUpdate`), and `HostConnection(entry:sink:clock:transportFactory:) throws` with `close()`, `static makeSession(for:clock:transportFactory:) throws`, `static advertisedAppVersion`, `static authRejectionReasons`.
- Test support produces `RecordingSink` with `events` and `statuses`.

- [ ] **Step 1: Write the sink protocol**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostSink.swift`:

```swift
public enum HostStatus: String, Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case unauthorized
    /// The entry itself is unusable, e.g. an endpoint that cannot form a URL.
    case invalid
}

/// What a connection reports into. The store that renders the menu implements
/// this in a later plan; tests use a recording fake. Every call is on the main actor.
@MainActor
public protocol HostSink: AnyObject {
    func setHost(_ hostId: String, label: String?, endpointHint: String)
    func removeHost(_ hostId: String)
    func setStatus(_ hostId: String, _ status: HostStatus)
    func setServerId(_ hostId: String, _ serverId: String)
    func setHostname(_ hostId: String, _ hostname: String?)
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool)
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool)
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate)
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate)
}
```

- [ ] **Step 2: Write the recording sink and the failing test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/RecordingSink.swift`:

```swift
@testable import PaseoIconCore

@MainActor
final class RecordingSink: HostSink {
    enum Event: Equatable {
        case setHost(String, label: String?, endpointHint: String)
        case removeHost(String)
        case setStatus(String, HostStatus)
        case setServerId(String, String)
        case setHostname(String, String?)
        case seedAgents(String, ids: [String], truncated: Bool)
        case seedWorkspaces(String, ids: [String], truncated: Bool)
        case agentUpdate(String, AgentUpdate)
        case workspaceUpdate(String, WorkspaceUpdate)
    }

    private(set) var events: [Event] = []

    var statuses: [HostStatus] {
        events.compactMap { if case .setStatus(_, let status) = $0 { status } else { nil } }
    }

    func setHost(_ hostId: String, label: String?, endpointHint: String) {
        events.append(.setHost(hostId, label: label, endpointHint: endpointHint))
    }
    func removeHost(_ hostId: String) { events.append(.removeHost(hostId)) }
    func setStatus(_ hostId: String, _ status: HostStatus) { events.append(.setStatus(hostId, status)) }
    func setServerId(_ hostId: String, _ serverId: String) { events.append(.setServerId(hostId, serverId)) }
    func setHostname(_ hostId: String, _ hostname: String?) { events.append(.setHostname(hostId, hostname)) }
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        events.append(.seedAgents(hostId, ids: agents.map(\.id), truncated: truncated))
    }
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        events.append(.seedWorkspaces(hostId, ids: workspaces.map(\.id), truncated: truncated))
    }
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) { events.append(.agentUpdate(hostId, update)) }
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) { events.append(.workspaceUpdate(hostId, update)) }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/HostConnectionTests.swift`:

```swift
import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostConnectionTests {
    @MainActor
    struct Harness {
        let clock = TestClock()
        let factory = FakeTransportFactory()
        let sink = RecordingSink()
        let connection: HostConnection

        init(entry: HostEntry = .directTcp(id: "h1", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: nil)) throws {
            connection = try HostConnection(entry: entry, sink: sink, clock: clock, transportFactory: factory.make)
        }

        var transport: FakeTransport { factory.last! }

        /// Finds the requestId of the last request of a given type the client sent.
        func requestId(ofType type: String) throws -> String {
            for text in transport.sentText.reversed() {
                let envelope = try jsonObject(text)
                guard let message = envelope["message"] as? [String: Any], message["type"] as? String == type else { continue }
                return try #require(message["requestId"] as? String)
            }
            Issue.record("no \(type) sent")
            throw NSError(domain: "HostConnectionTests", code: 1)
        }

        func openWithServerInfo(serverId: String = "srv-1", hostname: String? = "studio") {
            transport.simulateOpen()
            transport.simulateText(DaemonWire.serverInfo(serverId: serverId, hostname: hostname))
        }

        /// Answers both seed requests in the order the connection sends them.
        func answerSeed(agents: [String] = ["a1"], workspaces: [String] = ["w1"], agentsHasMore: Bool = false, workspacesHasMore: Bool = false) async throws {
            await settle()
            transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try requestId(ofType: "fetch_agents_request"), agents: agents, hasMore: agentsHasMore))
            await settle()
            transport.simulateText(DaemonWire.fetchWorkspacesResponse(requestId: try requestId(ofType: "fetch_workspaces_request"), workspaces: workspaces, hasMore: workspacesHasMore))
            await settle()
        }
    }

    @Test("registers the host before dialing and reports connecting")
    func registersHost() throws {
        let h = try Harness()
        #expect(h.sink.events.first == .setHost("h1", label: nil, endpointHint: "127.0.0.1:6767"))
        #expect(h.sink.statuses == [.connecting])
        #expect(h.transport.connectCalls == 1)
        #expect(h.transport.request.url.absoluteString == "ws://127.0.0.1:6767/ws")
    }

    @Test("dials the relay URL and no auth for a relay entry")
    func relayEntry() throws {
        let offer = ConnectionOffer(
            serverId: "srv-1",
            daemonPublicKeyB64: E2EEBox.exportPublicKey(E2EEBox.generateKeyPair().publicKey),
            relay: .init(endpoint: "relay.paseo.sh:443")
        )
        let h = try Harness(entry: .relay(id: "r1", label: "Studio", offer: offer))
        #expect(h.sink.events.first == .setHost("r1", label: "Studio", endpointHint: "relay.paseo.sh:443"))
        #expect(h.transport.request.url.absoluteString == "wss://relay.paseo.sh:443/ws?serverId=srv-1&role=client&v=2")
        #expect(h.transport.request.headers.isEmpty)
        #expect(h.transport.request.subprotocols.isEmpty)
    }

    @Test("an entry that cannot form a URL throws before the host is registered")
    func invalidEntry() {
        let sink = RecordingSink()
        #expect(throws: DaemonEndpointError.self) {
            try HostConnection(
                entry: .directTcp(id: "bad", label: nil, endpoint: "nonsense", useTls: false, password: nil),
                sink: sink,
                clock: TestClock(),
                transportFactory: FakeTransportFactory().make
            )
        }
        #expect(sink.events.isEmpty)
    }

    @Test("seeds both lists together, records serverId and hostname, then reports connected")
    func seeds() async throws {
        let h = try Harness()
        h.openWithServerInfo(serverId: "srv-1", hostname: "studio")
        await settle()
        let agentsRequest = try jsonObject(try #require(h.transport.sentText.last))["message"] as? [String: Any]
        #expect(agentsRequest?["type"] as? String == "fetch_agents_request")
        #expect((agentsRequest?["sort"] as? [[String: String]]) == [
            ["key": "status_priority", "direction": "asc"],
            ["key": "updated_at", "direction": "desc"],
        ])
        #expect((agentsRequest?["page"] as? [String: Any])?["limit"] as? Int == 200)
        try await h.answerSeed(agents: ["a1", "a2"], workspaces: ["w1"])
        let seededFrom = try #require(h.sink.events.firstIndex(of: .seedAgents("h1", ids: ["a1", "a2"], truncated: false)))
        #expect(Array(h.sink.events[seededFrom...]) == [
            .seedAgents("h1", ids: ["a1", "a2"], truncated: false),
            .seedWorkspaces("h1", ids: ["w1"], truncated: false),
            .setServerId("h1", "srv-1"),
            .setHostname("h1", "studio"),
            .setStatus("h1", .connected),
        ])
        #expect(h.sink.statuses == [.connecting, .connected])
    }

    @Test("asks for workspaces sorted by status_priority only")
    func workspaceSort() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try h.requestId(ofType: "fetch_agents_request")))
        await settle()
        let request = try jsonObject(try #require(h.transport.sentText.last))["message"] as? [String: Any]
        #expect(request?["type"] as? String == "fetch_workspaces_request")
        #expect((request?["sort"] as? [[String: String]]) == [["key": "status_priority", "direction": "asc"]])
        #expect((request?["subscribe"] as? [String: Any])?.isEmpty == true)
    }

    @Test("carries each page's hasMore through as a visible cap")
    func truncation() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed(agentsHasMore: true, workspacesHasMore: true)
        #expect(h.sink.events.contains(.seedAgents("h1", ids: ["a1"], truncated: true)))
        #expect(h.sink.events.contains(.seedWorkspaces("h1", ids: ["w1"], truncated: true)))
    }

    @Test("leaves the hostname nil when the daemon does not report one")
    func noHostname() async throws {
        let h = try Harness()
        h.openWithServerInfo(hostname: nil)
        try await h.answerSeed()
        #expect(h.sink.events.contains(.setHostname("h1", nil)))
    }

    @Test("retries a failed seed after two seconds instead of pinning a live host at disconnected")
    func seedRetry() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        let first = try h.requestId(ofType: "fetch_agents_request")
        h.transport.simulateText(DaemonWire.rpcError(requestId: first, error: "busy"))
        await settle()
        #expect(h.sink.statuses == [.connecting, .disconnected])
        await h.clock.advance(by: .seconds(2))
        await settle()
        let second = try h.requestId(ofType: "fetch_agents_request")
        #expect(second != first)
        try await h.answerSeed()
        #expect(h.sink.statuses == [.connecting, .disconnected, .connected])
    }

    @Test("applies neither list when only the workspace seed fails")
    func partialSeedFails() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        await settle()
        h.transport.simulateText(DaemonWire.fetchAgentsResponse(requestId: try h.requestId(ofType: "fetch_agents_request"), agents: ["a1"]))
        await settle()
        h.transport.simulateText(DaemonWire.rpcError(requestId: try h.requestId(ofType: "fetch_workspaces_request"), error: "busy"))
        await settle()
        #expect(!h.sink.events.contains { if case .seedAgents = $0 { true } else { false } })
        #expect(h.sink.statuses.last == .disconnected)
    }

    @Test("streams updates into the sink, reading removals from the right field")
    func streamsUpdates() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.transport.simulateText(DaemonWire.agentRemove(id: "a1"))
        h.transport.simulateText(DaemonWire.workspaceRemove(id: "w1"))
        #expect(h.sink.events.suffix(2) == [
            .agentUpdate("h1", .remove(agentId: "a1")),
            .workspaceUpdate("h1", .remove(id: "w1")),
        ])
    }

    @Test("reports disconnected when the daemon goes away and connecting on the retry")
    func disconnectAndRetry() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.transport.simulateClose(code: 1006, reason: "")
        #expect(h.sink.statuses.last == .disconnected)
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.sink.statuses.last == .connecting)
        #expect(h.factory.transports.count == 2)
    }

    @Test("classifies an auth rejection as unauthorized and stops retrying")
    func unauthorized() async throws {
        let h = try Harness(entry: .directTcp(id: "h1", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: "wrong"))
        h.transport.simulateOpen()
        h.transport.simulateClose(code: 4401, reason: "Incorrect password")
        #expect(h.sink.statuses == [.connecting, .unauthorized])
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1, "no reconnect behind backoff")
        #expect(h.sink.statuses == [.connecting, .unauthorized], "the disposed transition is not reported")
        #expect(!h.sink.events.contains(.removeHost("h1")), "the host stays visible")
    }

    @Test("close removes the host and disposes the session")
    func close() async throws {
        let h = try Harness()
        h.openWithServerInfo()
        try await h.answerSeed()
        h.connection.close()
        #expect(h.sink.events.last == .removeHost("h1"))
        #expect(h.transport.closedWith?.code == 1000)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter HostConnectionTests`
Expected: `error: cannot find 'HostConnection' in scope`.

- [ ] **Step 4: Write the host connection**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostConnection.swift`:

```swift
import Foundation

/// Owns one host: connect, seed, subscribe, and keep the sink's view of this
/// host's status honest. A port of `src/daemon/host-connection.ts`.
///
/// Seeding doubles as the daemon's required handshake: each stream only
/// starts once its own fetch has asked for it, so `agent_update` needs
/// `fetch_agents_request` and `workspace_update` needs `fetch_workspaces_request`.
@MainActor
public final class HostConnection {
    public static let agentPageLimit = 200
    public static let workspacePageLimit = 200
    public static let seedRetryDelay: Duration = .seconds(2)
    /// The protocol series this client mirrors; sent as `appVersion` in `hello`.
    public static let advertisedAppVersion = "0.4.0"
    /// Exact close reasons the daemon sends when the bearer token is missing or
    /// wrong (`attachAuthenticatedSocket`, websocket-server.js). They surface as
    /// the `disconnected` reason, never as a thrown error.
    public static let authRejectionReasons: Set<String> = ["Password required", "Incorrect password"]

    private let entry: HostEntry
    private let sink: any HostSink
    private let clock: any Clock<Duration>
    private let session: DaemonSession
    private var closed = false
    private var seedRetryTask: Task<Void, Never>?
    private var unsubscribeStatus: (() -> Void)?
    private var unsubscribeAgents: (() -> Void)?
    private var unsubscribeWorkspaces: (() -> Void)?

    /// Throws before the host is registered with the sink when the entry cannot
    /// form a URL, so a host with no connection that owns it never appears.
    public init(
        entry: HostEntry,
        sink: any HostSink,
        clock: any Clock<Duration>,
        transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport(request: $0) }
    ) throws {
        self.entry = entry
        self.sink = sink
        self.clock = clock
        self.session = try Self.makeSession(for: entry, clock: clock, transportFactory: transportFactory)
        sink.setHost(entry.id, label: entry.label, endpointHint: entry.endpointHint)

        unsubscribeAgents = session.onAgentUpdate { [weak self] update in
            guard let self else { return }
            self.sink.applyAgentUpdate(self.entry.id, update)
        }
        unsubscribeWorkspaces = session.onWorkspaceUpdate { [weak self] update in
            guard let self else { return }
            self.sink.applyWorkspaceUpdate(self.entry.id, update)
        }
        unsubscribeStatus = session.subscribeConnectionStatus { [weak self] state in
            self?.handleStatus(state)
        }
        session.connect()
    }

    public static func makeSession(
        for entry: HostEntry,
        clock: any Clock<Duration>,
        transportFactory: @escaping TransportFactory
    ) throws -> DaemonSession {
        // Stable across launches: the daemon keys live-session resume by clientId.
        let clientId = "paseo-menubar-\(entry.id)"
        switch entry {
        case .directTcp(_, _, let endpoint, let useTls, let password):
            let url = try DaemonEndpoints.daemonWebSocketURL(endpoint: endpoint, useTls: useTls)
            var config = DaemonSessionConfig(url: url, clientId: clientId, appVersion: advertisedAppVersion)
            config.password = password
            return DaemonSession(config: config, transportFactory: transportFactory, clock: clock)
        case .relay(_, _, let offer):
            let useTls = offer.relay.useTls ?? DaemonEndpoints.shouldUseTlsForDefaultHostedRelay(offer.relay.endpoint)
            let url = try DaemonEndpoints.relayWebSocketURL(
                endpoint: offer.relay.endpoint,
                useTls: useTls,
                serverId: offer.serverId
            )
            var config = DaemonSessionConfig(url: url, clientId: clientId, appVersion: advertisedAppVersion)
            config.e2eeDaemonPublicKeyB64 = offer.daemonPublicKeyB64
            return DaemonSession(config: config, transportFactory: transportFactory, clock: clock)
        }
    }

    /// Closes the session and removes the host from the sink.
    public func close() {
        closed = true
        clearSeedRetry()
        unsubscribeAll()
        session.close()
        sink.removeHost(entry.id)
    }

    // MARK: - Status

    private func handleStatus(_ state: ConnectionState) {
        guard !closed else { return }
        switch state {
        case .idle:
            return
        case .connecting:
            sink.setStatus(entry.id, .connecting)
        case .connected:
            requestSeed()
        case .disconnected(let reason):
            clearSeedRetry()
            if let reason, Self.authRejectionReasons.contains(reason) {
                sink.setStatus(entry.id, .unauthorized)
                stopRetrying()
                return
            }
            sink.setStatus(entry.id, .disconnected)
        case .disposed:
            clearSeedRetry()
            sink.setStatus(entry.id, .disconnected)
        }
    }

    /// A wrong password retried behind backoff forever is the failure mode to
    /// avoid. The host stays in the sink as `unauthorized` until `close()`.
    private func stopRetrying() {
        guard !closed else { return }
        closed = true
        clearSeedRetry()
        unsubscribeAll()
        session.close()
    }

    // MARK: - Seeding

    /// Seeds, and keeps trying while the socket stays up. A failed seed leaves
    /// a live connection with no lists, which reports as `disconnected`
    /// because the app cannot vouch for agents it never fetched.
    private func requestSeed() {
        clearSeedRetry()
        // Deferred so seeding never re-enters the session from inside its own listener.
        Task { [weak self] in
            guard let self, !self.closed, self.session.connectionState == .connected else { return }
            do {
                try await self.seed()
            } catch {
                guard !self.closed else { return }
                self.sink.setStatus(self.entry.id, .disconnected)
                guard self.session.connectionState == .connected else { return }
                self.seedRetryTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.clock.sleep(for: Self.seedRetryDelay)
                    } catch {
                        return
                    }
                    self.seedRetryTask = nil
                    self.requestSeed()
                }
            }
        }
    }

    private func seed() async throws {
        // `status_priority` ascending puts the agents that drive the icon at the
        // front of a capped page; `updated_at` is the daemon's default tiebreaker.
        let agents = try await session.fetchAgents(FetchAgentsOptions(
            sort: [SortKey(key: "status_priority", direction: "asc"), SortKey(key: "updated_at", direction: "desc")],
            pageLimit: Self.agentPageLimit,
            subscribe: true
        ))
        // No secondary key: the daemon's own ordering decides the rest.
        let workspaces = try await session.fetchWorkspaces(FetchWorkspacesOptions(
            sort: [SortKey(key: "status_priority", direction: "asc")],
            pageLimit: Self.workspacePageLimit,
            subscribe: true
        ))
        guard !closed else { return }
        // Both lists land together, after both fetches resolved. Caps are
        // visible, never silent: `hasMore` rides through as `truncated`.
        sink.seedAgents(entry.id, agents.entries.map(\.agent), truncated: agents.pageInfo.hasMore)
        sink.seedWorkspaces(entry.id, workspaces.entries, truncated: workspaces.pageInfo.hasMore)
        if let info = session.lastServerInfo {
            sink.setServerId(entry.id, info.serverId)
            sink.setHostname(entry.id, info.hostname)
        }
        sink.setStatus(entry.id, .connected)
    }

    private func clearSeedRetry() {
        seedRetryTask?.cancel()
        seedRetryTask = nil
    }

    private func unsubscribeAll() {
        unsubscribeStatus?()
        unsubscribeAgents?()
        unsubscribeWorkspaces?()
        unsubscribeStatus = nil
        unsubscribeAgents = nil
        unsubscribeWorkspaces = nil
    }
}
```

If you are running Task 6 before Task 7, remove `= { URLSessionWebSocketTransport(request: $0) }` from the initializer for now and restore it in Task 7.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 69 tests in 7 suites passed`.

- [ ] **Step 6: Mutate to prove the seed rule bites**

In `seed()`, temporarily move `sink.seedAgents(...)` to directly after the `fetchAgents` call, before `fetchWorkspaces`. Run `swift test --package-path PaseoIconPackage --filter HostConnectionTests`.
Expected: `applies neither list when only the workspace seed fails` fails. Revert and confirm green.

- [ ] **Step 7: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): host connection that seeds both lists together and classifies auth

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: The real WebSocket transport, against a Node echo server

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/URLSessionWebSocketTransport.swift`
- Create: `scripts/swift-test-ws-echo.mjs`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/NodeHarness.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/URLSessionWebSocketTransportTests.swift`

**Interfaces:**
- Consumes `DaemonTransport` from Task 4.
- Produces `URLSessionWebSocketTransport(request:)`, a `DaemonTransport`.
- Test support produces `NodeHarness(script:arguments:) async throws` with `info`, `int(_:)`, `string(_:)`, `stop()`, `static repoRoot`, and `eventually(timeout:_:) async -> Bool`.

- [ ] **Step 1: Write the echo server**

`scripts/swift-test-ws-echo.mjs`:

```javascript
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
```

Check it by hand: `node scripts/swift-test-ws-echo.mjs` prints `{"port":N}` and exits on Ctrl-D.

- [ ] **Step 2: Write the harness runner and the failing test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/NodeHarness.swift`:

```swift
import Foundation
import Testing

/// Runs one of the `scripts/swift-test-*.mjs` harnesses with `node`, reads the
/// JSON line it prints once ready, and stops it by closing its stdin.
final class NodeHarness: @unchecked Sendable {
    let info: [String: Any]
    private let process: Process
    private let stdin: Pipe

    /// The repository root: this file is `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/NodeHarness.swift`.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // PaseoIconCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PaseoIconPackage
            .deletingLastPathComponent()  // repo root
    }

    init(script: String, arguments: [String] = []) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", Self.repoRoot.appendingPathComponent("scripts/\(script)").path] + arguments
        process.currentDirectoryURL = Self.repoRoot
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.stdin = stdin

        var firstLine: String?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            firstLine = line
            break
        }
        guard let firstLine, let data = firstLine.data(using: .utf8),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            process.terminate()
            throw NSError(domain: "NodeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(script) printed no JSON line"])
        }
        self.info = info
    }

    func int(_ key: String) throws -> Int { try #require(info[key] as? Int) }
    func string(_ key: String) throws -> String { try #require(info[key] as? String) }

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Polls a condition in real time; for tests against real processes only.
@MainActor
func eventually(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await clock.sleep(for: .milliseconds(25))
    }
    return condition()
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/URLSessionWebSocketTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// Against `scripts/swift-test-ws-echo.mjs`, a `ws` server that reports the
/// handshake it saw, echoes frames, and closes with 4401 on request.
@MainActor
struct URLSessionWebSocketTransportTests {
    @MainActor
    final class Recorder {
        var opened = false
        var frames: [TransportFrame] = []
        var close: TransportClose?
        var errors: [String] = []
    }

    @Test("sends the bearer header and subprotocol, echoes text and binary, and surfaces the close reason")
    func roundTrip() async throws {
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(
            url: URL(string: "ws://127.0.0.1:\(port)/")!,
            headers: ["Authorization": "Bearer s3cret"],
            subprotocols: ["paseo.bearer.s3cret"]
        ))
        let recorder = Recorder()
        transport.onOpen = { recorder.opened = true }
        transport.onFrame = { recorder.frames.append($0) }
        transport.onClose = { recorder.close = $0 }
        transport.onError = { recorder.errors.append($0) }
        transport.connect()

        #expect(await eventually { recorder.opened && recorder.frames.count == 1 })
        guard case .text(let handshake)? = recorder.frames.first else {
            Issue.record("expected the handshake report")
            return
        }
        let report = try jsonObject(handshake)
        #expect(report["protocol"] as? String == "paseo.bearer.s3cret")
        #expect(report["authorization"] as? String == "Bearer s3cret")

        transport.send(.text("hello"))
        transport.send(.binary([1, 2, 3]))
        #expect(await eventually { recorder.frames.count == 3 })
        #expect(recorder.frames[1] == .text("hello"))
        #expect(recorder.frames[2] == .binary([1, 2, 3]))

        transport.send(.text("close-me"))
        #expect(await eventually { recorder.close != nil })
        #expect(recorder.close == TransportClose(code: 4401, reason: "Incorrect password"))
    }

    @Test("a refused connection closes with 1006 and an error")
    func refused() async throws {
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:1/")!))
        let recorder = Recorder()
        transport.onClose = { recorder.close = $0 }
        transport.onError = { recorder.errors.append($0) }
        transport.connect()
        #expect(await eventually { recorder.close != nil })
        #expect(recorder.close?.code == 1006)
        #expect(!recorder.errors.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --package-path PaseoIconPackage --filter URLSessionWebSocketTransportTests`
Expected: `error: cannot find 'URLSessionWebSocketTransport' in scope`.

- [ ] **Step 4: Write the transport**

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/URLSessionWebSocketTransport.swift`:

```swift
import Foundation

/// `DaemonTransport` over `URLSessionWebSocketTask`. The password rides as
/// both an `Authorization: Bearer` header and a `paseo.bearer.<password>`
/// subprotocol, which is what the daemon reads; the daemon echoes the selected
/// subprotocol so the handshake completes.
@MainActor
public final class URLSessionWebSocketTransport: DaemonTransport {
    public var onOpen: (() -> Void)?
    public var onFrame: ((TransportFrame) -> Void)?
    public var onClose: ((TransportClose) -> Void)?
    public var onError: ((String) -> Void)?

    private let request: TransportRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    public init(request: TransportRequest) {
        self.request = request
    }

    public func connect() {
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.subprotocols.isEmpty {
            urlRequest.setValue(request.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let delegate = Delegate(
            onOpen: { [weak self] in
                Task { @MainActor in self?.onOpen?() }
            },
            onClose: { [weak self] code, reason in
                Task { @MainActor in self?.finish(code: code, reason: reason) }
            }
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: urlRequest)
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    public func send(_ frame: TransportFrame) {
        guard let task, !closed else {
            onError?("Transport not connected")
            return
        }
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .text(let text): message = .string(text)
        case .binary(let bytes): message = .data(Data(bytes))
        }
        Task { [weak self] in
            do {
                try await task.send(message)
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    public func close(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
        session?.finishTasksAndInvalidate()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): onFrame?(.text(text))
                case .data(let data): onFrame?(.binary([UInt8](data)))
                @unknown default: break
                }
            } catch {
                handleReceiveFailure(error, task: task)
                return
            }
        }
    }

    /// `receive()` throws when the socket ends for any reason. If the server
    /// sent a close frame, the task already carries its code and reason; a
    /// dropped connection or a failed handshake carries neither and reports
    /// as 1006 with the error text.
    private func handleReceiveFailure(_ error: any Error, task: URLSessionWebSocketTask) {
        guard !closed else { return }
        onError?(error.localizedDescription)
        let closeCode = task.closeCode
        if closeCode == .invalid {
            finish(code: 1006, reason: error.localizedDescription)
        } else {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            finish(code: closeCode.rawValue, reason: reason)
        }
    }

    private func finish(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        session?.invalidateAndCancel()
        onClose?(TransportClose(code: code, reason: reason))
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let openHandler: @Sendable () -> Void
        private let closeHandler: @Sendable (Int, String) -> Void

        init(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Int, String) -> Void) {
            self.openHandler = onOpen
            self.closeHandler = onClose
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            openHandler()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            closeHandler(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }
}
```

Restore the `transportFactory` default argument in `HostConnection.init` if Task 6 removed it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 71 tests in 8 suites passed`. The transport suite takes about a second.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage scripts/swift-test-ws-echo.mjs
git commit -m "feat(native): URLSession WebSocket transport with bearer subprotocol, tested against ws

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: A real 0.4.0 daemon in the loop

**Files:**
- Create: `scripts/swift-test-daemon.mjs`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/RealDaemonTests.swift`

**Interfaces:**
- Consumes `HostConnection`, `RecordingSink`, `NodeHarness`, `eventually`.
- Produces the harness contract other tests can reuse: one JSON line `{"port":N,"serverId":"…","daemonPublicKeyB64":"…"}`, stops on stdin close, `--password <p>` optional.

- [ ] **Step 1: Write the daemon harness**

`scripts/swift-test-daemon.mjs`:

```javascript
// Boots a real `@getpaseo/server` 0.4.0 daemon on an OS-assigned port for the
// Swift integration tests, the same way `src/daemon/daemon-harness.ts` does
// for the vitest suite. Prints one JSON line when ready:
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
```

Check it by hand: `node scripts/swift-test-daemon.mjs` prints the JSON line within a few seconds and exits on Ctrl-D.

- [ ] **Step 2: Write the test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/RealDaemonTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// Against a real `@getpaseo/server` 0.4.0 daemon booted by
/// `scripts/swift-test-daemon.mjs`. Slow by design; the daemon takes a few
/// seconds to start.
@MainActor
struct RealDaemonTests {
    @Test("connects to a real daemon, seeds, and records its serverId and hostname")
    func connectsAndSeeds() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let serverId = try daemon.string("serverId")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: nil),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        #expect(sink.events.contains(.setServerId("real", serverId)))
        #expect(sink.events.contains(.seedWorkspaces("real", ids: [], truncated: false)))
        #expect(sink.events.contains(.seedAgents("real", ids: [], truncated: false)))
        #expect(sink.events.contains { if case .setHostname("real", let name) = $0 { name != nil } else { false } })
    }

    @Test("marks a wrong password unauthorized and stops retrying")
    func wrongPassword() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs", arguments: ["--password", "right"])
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: "wrong"),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .unauthorized })
    }

    @Test("reports disconnected when the daemon stops")
    func daemonStops() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        let port = try daemon.int("port")
        let sink = RecordingSink()
        let connection = try HostConnection(
            entry: .directTcp(id: "real", label: nil, endpoint: "127.0.0.1:\(port)", useTls: false, password: nil),
            sink: sink,
            clock: ContinuousClock()
        )
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .connected })
        daemon.stop()
        #expect(await eventually(timeout: .seconds(30)) { sink.statuses.last == .disconnected })
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `swift test --package-path PaseoIconPackage --filter RealDaemonTests`
Expected: 3 tests pass, each in about a second. If `swift-test-daemon.mjs printed no JSON line`, run the script by hand and read its stderr; the usual cause is `npm install` not having been run.

- [ ] **Step 4: Mutate to prove the auth classification bites**

In `HostConnection.authRejectionReasons`, temporarily remove `"Incorrect password"`. Run the suite.
Expected: `marks a wrong password unauthorized and stops retrying` fails (the host reports `disconnected` and keeps reconnecting). Revert and confirm green.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage scripts/swift-test-daemon.mjs
git commit -m "test(native): seed and auth against a real 0.4.0 daemon

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The relay path end to end

**Files:**
- Create: `scripts/relay-harness/package.json`
- Create: `scripts/relay-harness/wrangler.toml`
- Create: `scripts/swift-test-relay.mjs`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/RelayEndToEndTests.swift`

**Interfaces:**
- Consumes `HostConnection`, `ConnectionOffer`, `RecordingSink`, `NodeHarness`, `eventually`.
- Produces the harness contract `{"relayEndpoint":"127.0.0.1:N","serverId":"…","daemonPublicKeyB64":"…"}`.

- [ ] **Step 1: Write the relay harness package**

`scripts/relay-harness/package.json`:

```json
{
  "name": "paseo-menubar-relay-harness",
  "private": true,
  "type": "module",
  "description": "A local Paseo relay under wrangler dev, for the opt-in Swift relay end-to-end test. Installed separately because wrangler is large and only this test needs it.",
  "devDependencies": {
    "@getpaseo/relay": "0.4.0",
    "wrangler": "^4.105.0"
  }
}
```

`scripts/relay-harness/wrangler.toml`:

```toml
# The published relay worker, run locally. Mirrors upstream's
# packages/relay/wrangler.toml minus the production route and the cutover
# proxy variable: with PASEO_RELAY_UPSTREAM unset the worker serves the
# Durable Object directly.
name = "paseo-menubar-test-relay"
main = "node_modules/@getpaseo/relay/dist/cloudflare-adapter.js"
compatibility_date = "2024-12-01"

[[durable_objects.bindings]]
name = "RELAY"
class_name = "RelayDurableObject"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["RelayDurableObject"]
```

Install it (this is separate from the root install because wrangler is large and only this test needs it):

Run: `npm install --prefix scripts/relay-harness --no-audit --no-fund`
Expected: `node_modules/wrangler/bin/wrangler.js` exists under `scripts/relay-harness`. npm may warn that it skipped `workerd`'s postinstall script; the platform binary ships inside `@cloudflare/workerd-darwin-arm64` and `wrangler dev` runs without it.

The root `.gitignore` already ignores every `node_modules/`; Task 1 added `scripts/relay-harness/.wrangler/`.

- [ ] **Step 2: Write the harness script**

`scripts/swift-test-relay.mjs`:

```javascript
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
await waitForHealth(`http://127.0.0.1:${relayPort}/health`, 90_000);

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
```

Check it by hand: `node scripts/swift-test-relay.mjs` streams wrangler's startup to stderr, prints the JSON line within about ten seconds, and exits on Ctrl-D.

- [ ] **Step 3: Write the test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/RelayEndToEndTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// The full relay path: a local relay under `wrangler dev`, a real daemon
/// registered with it, and this client dialing through it with E2EE. Opt-in
/// because it needs `scripts/relay-harness` installed and takes a minute:
///
///     PASEO_ICON_RELAY_E2E=1 swift test --filter RelayEndToEndTests
@MainActor
struct RelayEndToEndTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["PASEO_ICON_RELAY_E2E"] == "1" }

    @Test("connects through a relay with E2EE and seeds", .enabled(if: enabled))
    func relayRoundTrip() async throws {
        let harness = try await NodeHarness(script: "swift-test-relay.mjs")
        defer { harness.stop() }
        let offer = ConnectionOffer(
            serverId: try harness.string("serverId"),
            daemonPublicKeyB64: try harness.string("daemonPublicKeyB64"),
            relay: .init(endpoint: try harness.string("relayEndpoint"), useTls: false)
        )
        let sink = RecordingSink()
        let connection = try HostConnection(entry: .relay(id: "relayed", label: nil, offer: offer), sink: sink, clock: ContinuousClock())
        defer { connection.close() }
        #expect(await eventually(timeout: .seconds(60)) { sink.statuses.last == .connected })
        #expect(sink.events.contains(.setServerId("relayed", offer.serverId)))
        #expect(sink.events.contains(.seedWorkspaces("relayed", ids: [], truncated: false)))
    }
}
```

- [ ] **Step 4: Run it opt-in, and confirm it is skipped otherwise**

Run: `PASEO_ICON_RELAY_E2E=1 swift test --package-path PaseoIconPackage --filter RelayEndToEndTests`
Expected: `connects through a relay with E2EE and seeds` passes in a few seconds.

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 75 tests in 10 suites passed`; the relay test is reported as skipped inside that count.

- [ ] **Step 5: Mutate to prove the relay path is real**

In `E2EEChannel.handleBaseOpen`, temporarily replace `let pair = E2EEBox.generateKeyPair()` with a pair whose secret key is 32 zero bytes: `let pair = E2EEKeyPair(publicKey: [UInt8](repeating: 0, count: 32), secretKey: [UInt8](repeating: 0, count: 32))`. Run the opt-in test.
Expected: it fails; the daemon cannot open the client's frames and `connected` never arrives. Revert and confirm green.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage scripts/relay-harness/package.json scripts/relay-harness/wrangler.toml scripts/swift-test-relay.mjs
git commit -m "test(native): relay end to end through a local wrangler relay with E2EE

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: The probe CLI

**Files:**
- Modify: `PaseoIconPackage/Package.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconProbe/main.swift`

**Interfaces:**
- Consumes `HostConnection`, `HostSink`, `ConnectionOffer`, `HostEntry`.
- Produces the `PaseoIconProbe` executable.

- [ ] **Step 1: Add the executable to the manifest**

In `PaseoIconPackage/Package.swift`, add to `products`:

```swift
        .executable(name: "PaseoIconProbe", targets: ["PaseoIconProbe"]),
```

and to `targets`, after the `PaseoIconCore` target:

```swift
        .executableTarget(name: "PaseoIconProbe", dependencies: ["PaseoIconCore"]),
```

- [ ] **Step 2: Write the probe**

`PaseoIconPackage/Sources/PaseoIconProbe/main.swift`:

```swift
import AppKit
import Foundation
import PaseoIconCore

// A terminal probe for one host: prints every status transition, the
// server_info, the seeded counts, and each streamed update until Ctrl-C.
// This is how relay connectivity is checked against a real host without a
// menu bar in the loop.
//
//   swift run PaseoIconProbe --offer 'paseo://…#offer=…'
//   swift run PaseoIconProbe --endpoint 127.0.0.1:6767 [--password secret] [--tls]

@MainActor
final class PrintingSink: HostSink {
    func setHost(_ hostId: String, label: String?, endpointHint: String) {
        print("host \(hostId): label=\(label ?? "-") endpoint=\(endpointHint)")
    }
    func removeHost(_ hostId: String) { print("host \(hostId): removed") }
    func setStatus(_ hostId: String, _ status: HostStatus) { print("status: \(status.rawValue)") }
    func setServerId(_ hostId: String, _ serverId: String) { print("serverId: \(serverId)") }
    func setHostname(_ hostId: String, _ hostname: String?) { print("hostname: \(hostname ?? "-")") }
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        print("seeded \(agents.count) agents\(truncated ? " (truncated)" : "")")
    }
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        print("seeded \(workspaces.count) workspaces\(truncated ? " (truncated)" : "")")
        for workspace in workspaces {
            print("  \(workspace.status)\t\(workspace.projectDisplayName) / \(workspace.name)")
        }
    }
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) {
        switch update {
        case .upsert(let agent): print("agent upsert: \(agent.id) status=\(agent.status)")
        case .remove(let agentId): print("agent remove: \(agentId)")
        }
    }
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) {
        switch update {
        case .upsert(let workspace): print("workspace upsert: \(workspace.name) status=\(workspace.status)")
        case .remove(let id): print("workspace remove: \(id)")
        }
    }
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: PaseoIconProbe --offer <pairing url>
           PaseoIconProbe --endpoint <host:port> [--password <password>] [--tls]

    """.utf8))
    exit(2)
}

func parseEntry(_ arguments: [String]) -> HostEntry {
    var offer: String?
    var endpoint: String?
    var password: String?
    var tls = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() -> String {
            index += 1
            guard index < arguments.count else { usage() }
            return arguments[index]
        }
        switch argument {
        case "--offer": offer = value()
        case "--endpoint": endpoint = value()
        case "--password": password = value()
        case "--tls": tls = true
        default: usage()
        }
        index += 1
    }
    if let offer {
        do {
            return .relay(id: "probe", label: nil, offer: try ConnectionOffer.parse(fromURL: offer))
        } catch {
            FileHandle.standardError.write(Data("invalid offer: \(error)\n".utf8))
            exit(2)
        }
    }
    if let endpoint {
        return .directTcp(id: "probe", label: nil, endpoint: endpoint, useTls: tls, password: password)
    }
    usage()
}

// Line-buffer stdout so transitions show up as they happen when piped to a file or another process.
setvbuf(stdout, nil, _IOLBF, 0)
let entry = parseEntry(Array(CommandLine.arguments.dropFirst()))
let sink = PrintingSink()
let connection: HostConnection
do {
    connection = try HostConnection(entry: entry, sink: sink, clock: ContinuousClock())
} catch {
    FileHandle.standardError.write(Data("cannot dial: \(error)\n".utf8))
    exit(2)
}
signal(SIGINT) { _ in exit(0) }
withExtendedLifetime(connection) {
    RunLoop.main.run()
}
```

- [ ] **Step 3: Run it against a real daemon**

In one terminal: `node scripts/swift-test-daemon.mjs` and note the port.
In another: `swift run --package-path PaseoIconPackage PaseoIconProbe --endpoint 127.0.0.1:<port>`
Expected output, then it keeps running until Ctrl-C:

```
host probe: label=- endpoint=127.0.0.1:<port>
status: connecting
seeded 0 agents
seeded 0 workspaces
serverId: srv_…
hostname: <your machine>
status: connected
```

Then the check only a human can do, against your real relay host: `swift run --package-path PaseoIconPackage PaseoIconProbe --offer '<the pairing URL from paseo daemon pair>'`. Expected: `status: connected` with your workspaces listed by bucket, a `workspace upsert:` line when one changes state, and `status: disconnected` followed by `status: connecting` if you stop the daemon. Record what you saw in the commit message; do not claim it if you did not run it.

- [ ] **Step 4: Run the whole suite**

Run: `swift test --package-path PaseoIconPackage && npx vitest run && npm run typecheck`
Expected: 75 Swift tests pass; vitest reports 269 tests in 19 files (the 267 existing plus the 2 from Task 3); typecheck is clean.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): terminal probe for one host, direct or relayed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: The menu bar app skeleton and the working notes

**Files:**
- Modify: `PaseoIconPackage/Package.swift`
- Create: `PaseoIconPackage/Sources/PaseoIcon/PaseoIconApp.swift`
- Modify: `CLAUDE.md` (the "Working here" section)

**Interfaces:**
- Produces the `PaseoIcon` executable. Later plans give it hosts, rows, and the count.

- [ ] **Step 1: Finish the manifest**

Replace `PaseoIconPackage/Package.swift` with its final form:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PaseoIconPackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaseoIconCore", targets: ["PaseoIconCore"]),
        .executable(name: "PaseoIcon", targets: ["PaseoIcon"]),
        .executable(name: "PaseoIconProbe", targets: ["PaseoIconProbe"]),
    ],
    dependencies: [
        // Pinned exactly: the E2EE wire format is libsodium's crypto_box, and the
        // xcframework this ships is a static archive, so signing needs no extra step.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
        // TestClock, so timers (hello retry, connect timeout, ping, backoff) are
        // tested deterministically instead of with real sleeps.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "PaseoIconCore",
            dependencies: [.product(name: "Sodium", package: "swift-sodium")]
        ),
        .executableTarget(name: "PaseoIcon", dependencies: ["PaseoIconCore"]),
        .executableTarget(name: "PaseoIconProbe", dependencies: ["PaseoIconCore"]),
        .testTarget(
            name: "PaseoIconCoreTests",
            dependencies: [
                "PaseoIconCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Write the app**

`PaseoIconPackage/Sources/PaseoIcon/PaseoIconApp.swift`:

```swift
import AppKit
import SwiftUI

/// The menu bar app. This preview build shows a static item with a Quit entry;
/// hosts, rows, and the count arrive with later plans.
@main
struct PaseoIconApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            Text("Paseo Icon (native preview)")
            Divider()
            Button("Quit Paseo Icon") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "circle.dashed")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon; this app is the menu bar item. The bundled build sets
        // LSUIElement too, but `swift run` has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 3: Build and run it**

Run: `swift build --package-path PaseoIconPackage --product PaseoIcon`
Expected: `Build complete!`.

Run: `swift run --package-path PaseoIconPackage PaseoIcon`
Expected, by a human looking at the menu bar: a dashed-circle item appears with no Dock icon; clicking it shows `Paseo Icon (native preview)`, a divider, and `Quit Paseo Icon`, and Quit exits. This writes no state anywhere. No agent can see a menu bar; say plainly whether this check was done.

- [ ] **Step 4: Record the commands in CLAUDE.md**

In `CLAUDE.md`, under "Working here", extend the command block:

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npx vitest run                              # 269 tests, 19 files
npm run typecheck
npm run fixtures:registry                   # regenerate LevelDB test fixtures
npm run fixtures:e2ee                       # regenerate the tweetnacl E2EE vectors
npm run test:swift                          # 75 Swift tests; needs npm install first
PASEO_ICON_RELAY_E2E=1 npm run test:swift -- --filter RelayEndToEndTests   # after: npm install --prefix scripts/relay-harness
swift run --package-path PaseoIconPackage PaseoIconProbe --offer '<pairing url>'   # relay check against a real host
```

and add these bullets below the existing ones:

```markdown
- **The native app lives in `PaseoIconPackage/` and does not touch the Electron
  build.** Its integration tests spawn `node` for `scripts/swift-test-*.mjs`, so
  the root `npm install` has to have run. `swift run PaseoIcon` writes no state.
- **The relay end-to-end test is opt-in** because it needs `wrangler` from
  `scripts/relay-harness`, installed separately. The daemon and echo harnesses
  need nothing beyond the root install.
```

- [ ] **Step 5: Run everything one last time**

Run: `swift test --package-path PaseoIconPackage && npx vitest run && npm run typecheck`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage CLAUDE.md
git commit -m "feat(native): MenuBarExtra app skeleton and working notes for the Swift package

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## What comes next

This plan stops at a library that speaks the wire and two executables that prove it. The next plans, in the order the design doc sets, are the registry reader port against the existing LevelDB fixtures, then the store, fleet, and view model to parity with the Electron menu, then packaging and the cask's macOS floor, then UI beyond parity.
