# Native App Parity and Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the native Swift app from a wire-level foundation to a full replacement for the Electron build: read the Paseo desktop app's host registry, render the same five-bucket menu with the same labels and click targets, ship a signed and notarized bundle through the existing Homebrew cask, and delete Electron.

**Architecture:** Everything that is not AppKit or SwiftUI goes in `PaseoIconCore`, including the entire menu: `MenuModel` decides every row as data and the SwiftUI layer renders that list and nothing else. The registry reader is a straight port of the TypeScript one against the same committed LevelDB fixtures. The store, fleet, and view model are ports too, with one simplification the Swift side earns: `HostConnection.close()` is synchronous, so the fleet needs no serialization. The app target holds the object graph, the rendered menu bar label, the login item, and `NSWorkspace`.

**Tech Stack:** Swift 6.1 tools (Xcode 27 / Swift 6.4 on the maintainer's machine), Swift Package Manager, SwiftUI `MenuBarExtra`, Swift Testing, swift-sodium 0.11.0 (exact), swift-clocks 1.0.4+, CoreServices FSEvents, ServiceManagement, Node 26 with `@getpaseo/server` 0.4.0 for the integration harnesses.

**Spec:** `docs/superpowers/2026-09-16-native-swift-app-design.md` (binding for the native build). Behaviour rules come from `docs/superpowers/2026-08-16-standalone-menubar-app-design.md` and `docs/superpowers/2026-08-19-registry-sync-design.md`, both binding. Plan 1, `docs/superpowers/plans/2026-09-16-native-app-foundation.md`, built the foundation this plan sits on.

## Global Constraints

- **The TypeScript is the specification.** Every module in Tasks 2 through 9 is a port of a named file under `src/`. When this plan's code and that file disagree, the TypeScript wins and the difference is a bug in this plan — except where a "Deliberate difference" note says otherwise.
- **Never derive a workspace's state.** Render `WorkspaceDescriptor.status`, the bucket the daemon computed. A bucket this build does not know is dropped from the menu, never guessed at, never counted.
- **Section order and labels are copied, not invented.** They come from `STATUS_BUCKET_ORDER` and `STATUS_BUCKET_LABELS` upstream: `needs_input`, `failed`, `attention`, `running`, `done`, labelled "Needs input", "Failed", "Ready to review", "Working", "Done".
- **No silent caps.** A section caps at 15 rows and renders "…and N more". A capped seed page renders "Not all workspaces shown · <host>" or "Not all agents loaded · <host>". A host the registry could not map is named in the error row.
- **Never crash the tray.** Invalid config keeps the last known-good state and surfaces a configuration row. Nothing in the registry path throws out of `start` or `refresh`.
- **Hosts come from the Paseo desktop app's Chromium localStorage and nothing else.** The record is `@paseo:daemon-registry` under origin `paseo://app` in `~/Library/Application Support/Paseo/Local Storage/leveldb`. No `config.json`, no pairing flow.
- **The LevelDB reader never takes the lock and never writes.** Every block's CRC32C is verified before it is parsed. A file gone by read time (`ENOENT`) means the listing was stale and the directory is listed again; any other read error is damage. An unknown compression type is refused by name rather than guessed at.
- **One bad profile never costs another host.** Only a record that is not an array at all fails the whole read.
- **The wire pin is unchanged:** `protocolVersion: 1` and the message shapes of `@getpaseo/protocol` 0.4.0, decoded leniently.
- **Session-layer and UI-layer classes are `@MainActor`**; clocks, filesystems, transports, and connection factories are injected so every test runs without a socket, a timer, or a menu bar.
- **The bundle is `PaseoIcon.app`, the display name is "Paseo Icon", the cask token is `paseo-menubar`, and the bundle id is `br.eng.gustavo.paseo-menubar`.** All four are correct and all four are different.
- **macOS floor is 14.0**, declared in `PaseoIconPackage/Package.swift`, in `MIN_MACOS` in `scripts/native-bundle.mjs`, and in the cask's `depends_on macos: :sonoma`. Raising it means raising all three.
- **Do not run `swift run PaseoIcon`, `npm run dist`, or `electron .`** unless a step says to. The menu bar cannot be seen from a terminal; say so rather than narrating a check you did not perform.
- Every commit message ends with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Run Swift from the repository root: `swift test --package-path PaseoIconPackage`. Integration tests spawn `node` from `PATH`, so the root `npm install` must have run.

## Provenance

Every Swift file, Node script, and test in this plan was written into a scratch copy of this repository, compiled, and run on 2026-09-16 before the plan was written. Results on the maintainer's machine, Xcode 27 / Swift 6.4:

| Check | Result |
| --- | --- |
| Swift tests | 296 in 29 suites, all passing (295 as written, plus one the Task 3 review added) |
| Script tests (vitest) | 42 in 4 files, all passing |
| Registry reader against the committed LevelDB fixtures | 112 tests, ported one-for-one from the TypeScript suites |
| Fleet against a real `@getpaseo/server` 0.4.0 daemon | connected, menu rendered |
| `scripts/native-bundle.mjs` end to end | built, signed, **accepted by Apple**, stapled, dmg and zip written |
| Gatekeeper on the built bundle | `accepted, source=Notarized Developer ID` |
| The built app launched | started, icons loaded, survived, no stderr |

If a toolchain difference surfaces a compile error, fix that error; do not re-derive the design.

**Two bugs in Plan 1's shipped code were found while doing this and are fixed by Task 1 and Task 7.** Both were invisible to Plan 1's own suite and only appeared when the full suite ran under load. Do not skip Task 1.

## File Structure

| Path | Responsibility |
| --- | --- |
| `PaseoIconCore/ErrorText.swift` | `MessageError` and `errorText`, the one narrowing every failure path shares. |
| `PaseoIconCore/Config/AppConfig.swift` | The validated host set and its fingerprint. The only way a config is built. |
| `PaseoIconCore/Registry/Binary.swift` | Varints, CRC32C, LevelDB's checksum mask, byte comparison. |
| `PaseoIconCore/Registry/Snappy.swift` | The raw snappy decoder LevelDB blocks need. |
| `PaseoIconCore/Registry/SSTable.swift` | One `.ldb`: footer, index, blocks, checksums. |
| `PaseoIconCore/Registry/WAL.swift` | One `.log`: record framing and batches. |
| `PaseoIconCore/Registry/LocalStorage.swift` | Chromium localStorage key framing and value encoding. |
| `PaseoIconCore/Registry/FileSystem.swift` | The two filesystem calls the reader makes, injected. |
| `PaseoIconCore/Registry/LevelDBReader.swift` | A LevelDB directory: newest sequence wins. |
| `PaseoIconCore/Registry/PaseoRegistry.swift` | Locate the Paseo app, validate profiles, map to `HostEntry`. |
| `PaseoIconCore/Registry/RegistrySession.swift` | Watch, debounce, poll, fingerprint, apply, own the error row. |
| `PaseoIconCore/Registry/RegistryWatcher.swift` | Keeping the directory watch attached. |
| `PaseoIconCore/Registry/FSEventsWatch.swift` | The production watch: FSEvents with file-level events. |
| `PaseoIconCore/Store/HostStore.swift` | Replicated workspaces and agents, keyed by host. The `HostSink`. |
| `PaseoIconCore/Daemon/HostFleet.swift` | The set of connections: apply, isolate, retry, web fallback. |
| `PaseoIconCore/Tray/TrayViewModel.swift` | Store state to icon, count, sections, click targets, host names. |
| `PaseoIconCore/Tray/MenuModel.swift` | The menu as data. Every row, label, and rule. |
| `PaseoIconCore/Launch/OpenPaseo.swift` | Deep links, with the browser fallback. |
| `PaseoIcon/TrayIcons.swift` | The five bucket glyphs as template images. |
| `PaseoIcon/MenuBarLabel.swift` | The rendered menu bar item: glyph plus count. |
| `PaseoIcon/MenuContent.swift` | Renders `[MenuItem]`. Decides nothing. |
| `PaseoIcon/AppCoordinator.swift` | The object graph, login item, alerts, `NSWorkspace`. |
| `PaseoIcon/PaseoIconApp.swift` | The `MenuBarExtra` scene and the app delegate. |
| `scripts/native-bundle.mjs` | Build, sign, notarize, staple, dmg and zip. |

---

### Task 1: Fix the WebSocket send ordering

**Files:**
- Modify: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/URLSessionWebSocketTransport.swift`
- Test: `PaseoIconPackage/Tests/PaseoIconCoreTests/URLSessionWebSocketTransportTests.swift`

**Interfaces:**
- Produces no new API. `send(_:)` keeps its signature and gains an ordering guarantee every later task depends on.

**Why this is first.** `send(_:)` spawns one unstructured `Task` per frame. Unstructured tasks are scheduled independently, so two sends can complete in either order. On this wire that lets a `fetch_agents_request` overtake the `hello` that has to precede it, and the daemon answers neither. Plan 1's own suite never caught it because its transport test sends two frames on an idle machine; the full suite under load reproduced it on the first run.

- [ ] **Step 1: Write the failing test**

Add to `URLSessionWebSocketTransportTests`, before the refused-connection test:

```swift
    @Test("keeps frames in the order they were handed over, under load")
    func sendOrder() async throws {
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        let recorder = Recorder()
        transport.onOpen = { recorder.opened = true }
        transport.onFrame = { recorder.frames.append($0) }
        transport.connect()
        #expect(await eventually { recorder.opened && recorder.frames.count == 1 })

        // One unstructured Task per frame does not preserve order: this fails
        // without the send chain, reliably at this count, and intermittently
        // at two frames under a busy machine.
        let sent = (0..<40).map { "frame-\($0)" }
        for text in sent { transport.send(.text(text)) }

        #expect(await eventually { recorder.frames.count == sent.count + 1 })
        let echoed = recorder.frames.dropFirst().compactMap { frame -> String? in
            if case .text(let text) = frame { return text }
            return nil
        }
        #expect(echoed == sent)
    }
```

- [ ] **Step 2: Run it to watch it fail**

Run: `swift test --package-path PaseoIconPackage --filter URLSessionWebSocketTransportTests`
Expected: `sendOrder` fails on `echoed == sent`; the other two pass.

- [ ] **Step 3: Chain the sends**

In `URLSessionWebSocketTransport`, add a stored property beside `receiveTask`:

```swift
    /// The tail of the send chain, so frames keep their order.
    private var sendTail: Task<Void, Never> = Task {}
```

Replace the body of `send(_:)` with:

```swift
    /// Frames go out in the order they were handed over. `URLSessionWebSocketTask.send`
    /// is async, and one unstructured `Task` per frame does not preserve
    /// order: two sends can complete in either order, which on this wire would
    /// let a `fetch_agents_request` overtake the `hello` that has to precede
    /// it. Each send therefore awaits the previous one.
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
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous.value
            do {
                try await task.send(message)
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }
```

And in `close(code:reason:)`, cancel it alongside the receive loop — add `sendTail.cancel()` directly after `receiveTask?.cancel()`.

- [ ] **Step 4: Run it to watch it pass**

Run: `swift test --package-path PaseoIconPackage --filter URLSessionWebSocketTransportTests`
Expected: `Test run with 3 tests in 1 suite passed`.

Then the whole suite, twice, because this is a concurrency fix and one green run proves less than two:
Run: `swift test --package-path PaseoIconPackage && swift test --package-path PaseoIconPackage`
Expected: `Test run with 79 tests in 10 suites passed` both times.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "fix(native): send WebSocket frames in order

One unstructured Task per frame does not preserve order, so a fetch could
overtake the hello that has to precede it. Found by running the full suite
under load; the two-frame test that shipped could not see it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: LevelDB binary primitives and snappy

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/Binary.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/Snappy.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/BinaryTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/SnappyTests.swift`
- Create (copied): `PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/registry/**`

**Ports:** `src/registry/binary.ts` and its test. Snappy has no TypeScript counterpart: the Electron build calls `snappyjs`, and this decoder replaces that dependency so the reader stays plain Swift with nothing to link.

**Interfaces:**
- Produces `Binary.readVarint32(_:at:)`, `readVarint64(_:at:)`, `readUInt16LE(_:at:)`, `readUInt32LE(_:at:)`, `crc32c(_:)` for both `[UInt8]` and `ArraySlice<UInt8>`, `maskCrc(_:)`, `unmaskCrc(_:)`, `compare(_:_:)`, and `BinaryError`.
- Produces `Snappy.uncompress(_:) throws -> [UInt8]` and `SnappyError`.

- [ ] **Step 1: Copy the LevelDB fixtures into the package**

The same directories `npm run fixtures:registry` generates, which the TypeScript suites already test against. They move rather than being regenerated, so the Swift reader is checked against the exact bytes the TypeScript reader was.

```bash
mkdir -p PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/registry
cp -R src/registry/__fixtures__/* PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/registry/
ls PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/registry
```

Expected: `compacted deleted log-only multi-block superseded utf16`.

Point the generator at both places so a regeneration cannot leave them divergent. In `scripts/make-registry-fixtures.mjs`, after the existing `root` constant, add:

```js
// The Swift tests read the same bytes the TypeScript ones do. Written to both
// places by the same run, so a regeneration cannot leave them divergent.
const swiftRoot = path.join(
  fileURLToPath(new URL("../PaseoIconPackage/Tests/PaseoIconCoreTests/Fixtures/registry", import.meta.url)),
);
```

and at the end of `build`, after the artifact cleanup, add:

```js
  await rm(path.join(swiftRoot, name), { recursive: true, force: true });
  await mkdir(path.dirname(path.join(swiftRoot, name)), { recursive: true });
  await cp(dir, path.join(swiftRoot, name), { recursive: true });
```

adding `cp` to the `node:fs/promises` import.

- [ ] **Step 2: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/Registry/Binary.swift`:

```swift
import Foundation

public enum BinaryError: Error, Equatable {
    /// The buffer ended inside a varint. Thrown rather than returning a partial
    /// value: every caller is parsing a file another process is actively
    /// writing, and a silently short read there is the difference between
    /// "retry" and "wrong credentials".
    case varintPastEnd(String)
    case varintTooLong(String)
}

/// Varint, checksum, and little-endian primitives for LevelDB's on-disk
/// formats. Knows nothing about LevelDB itself: both the SSTable reader and
/// the write-ahead-log reader need these, and keeping them separate is what
/// lets each of those be tested against its own format alone.
public enum Binary {
    public static func readVarint32(_ buf: [UInt8], at pos: Int) throws -> (value: UInt32, next: Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var cursor = pos
        while true {
            guard cursor >= 0, cursor < buf.count else {
                throw BinaryError.varintPastEnd("varint32 ran past end of buffer")
            }
            let byte = buf[cursor]
            cursor += 1
            result |= UInt32(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw BinaryError.varintTooLong("varint32 is longer than 5 bytes") }
        }
        return (result, cursor)
    }

    /// Block offsets and sizes are the only 64-bit varints read, and they are
    /// bounded by file size.
    public static func readVarint64(_ buf: [UInt8], at pos: Int) throws -> (value: UInt64, next: Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = pos
        while true {
            guard cursor >= 0, cursor < buf.count else {
                throw BinaryError.varintPastEnd("varint64 ran past end of buffer")
            }
            let byte = buf[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw BinaryError.varintTooLong("varint64 is longer than 10 bytes") }
        }
        return (result, cursor)
    }

    public static func readUInt16LE(_ buf: [UInt8], at pos: Int) -> UInt16 {
        UInt16(buf[pos]) | (UInt16(buf[pos + 1]) << 8)
    }

    public static func readUInt32LE(_ buf: [UInt8], at pos: Int) -> UInt32 {
        UInt32(buf[pos]) | (UInt32(buf[pos + 1]) << 8) | (UInt32(buf[pos + 2]) << 16) | (UInt32(buf[pos + 3]) << 24)
    }

    // CRC32C (Castagnoli), reversed polynomial. LevelDB uses this, not CRC32.
    private static let crc32cTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0x82f6_3b78 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32c(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = crc32cTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    public static func crc32c(_ bytes: [UInt8]) -> UInt32 { crc32c(bytes[...]) }

    private static let maskDelta: UInt32 = 0xa282_ead8

    /// LevelDB's CRC mask: stored checksums are rotated and offset so that a
    /// checksum never appears verbatim in the data it covers.
    public static func maskCrc(_ crc: UInt32) -> UInt32 {
        let rot = (crc >> 15) | (crc << 17)
        return rot &+ maskDelta
    }

    public static func unmaskCrc(_ masked: UInt32) -> UInt32 {
        let rot = masked &- maskDelta
        return (rot >> 17) | (rot << 15)
    }

    /// Unsigned bytewise comparison, a shorter prefix ordering first: the
    /// order LevelDB's default comparator and Node's `Buffer.compare` share.
    public static func compare(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex {
            if a[ia] != b[ib] { return a[ia] < b[ib] ? -1 : 1 }
            ia += 1
            ib += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/Snappy.swift`:

```swift
public enum SnappyError: Error, Equatable {
    case truncated
    case badOffset
    case lengthMismatch(expected: Int, actual: Int)
}

/// Decoder for the raw snappy format LevelDB stores its compressed blocks in
/// (no framing, no CRC: the block trailer's CRC32C covers the compressed
/// bytes). Hand-written rather than a dependency for the same reason the
/// LevelDB reader is: the whole parser stays plain Swift with nothing to link.
public enum Snappy {
    public static func uncompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        let bytes = Array(input)
        var pos = 0
        // Preamble: the uncompressed length as a varint.
        var expected = 0
        var shift = 0
        while true {
            guard pos < bytes.count else { throw SnappyError.truncated }
            let byte = bytes[pos]
            pos += 1
            expected |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { throw SnappyError.truncated }
        }
        var out: [UInt8] = []
        out.reserveCapacity(expected)

        while pos < bytes.count {
            let tag = bytes[pos]
            pos += 1
            switch tag & 0x03 {
            case 0:
                // Literal. Lengths up to 60 ride in the tag; longer ones use
                // 1 to 4 trailing little-endian bytes.
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard pos + extra <= bytes.count else { throw SnappyError.truncated }
                    length = 0
                    for i in 0..<extra { length |= Int(bytes[pos + i]) << (8 * i) }
                    pos += extra
                }
                length += 1
                guard pos + length <= bytes.count else { throw SnappyError.truncated }
                out.append(contentsOf: bytes[pos..<(pos + length)])
                pos += length
            case 1:
                // Copy, 1-byte offset: length 4 to 11, offset 11 bits.
                guard pos < bytes.count else { throw SnappyError.truncated }
                let length = 4 + Int((tag >> 2) & 0x07)
                let offset = (Int(tag >> 5) << 8) | Int(bytes[pos])
                pos += 1
                try copy(into: &out, offset: offset, length: length)
            case 2:
                guard pos + 2 <= bytes.count else { throw SnappyError.truncated }
                let length = Int(tag >> 2) + 1
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
                pos += 2
                try copy(into: &out, offset: offset, length: length)
            default:
                guard pos + 4 <= bytes.count else { throw SnappyError.truncated }
                let length = Int(tag >> 2) + 1
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
                pos += 4
                try copy(into: &out, offset: offset, length: length)
            }
        }
        guard out.count == expected else {
            throw SnappyError.lengthMismatch(expected: expected, actual: out.count)
        }
        return out
    }

    /// A copy may overlap its own output (offset 1 repeats a byte), so it is
    /// appended one byte at a time rather than as a range.
    private static func copy(into out: inout [UInt8], offset: Int, length: Int) throws {
        guard offset > 0, offset <= out.count else { throw SnappyError.badOffset }
        let start = out.count - offset
        for i in 0..<length {
            out.append(out[start + i])
        }
    }
}
```

- [ ] **Step 3: Write the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/BinaryTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct BinaryTests {
    @Test("reads a single-byte varint32 and reports the next offset")
    func singleByte() throws {
        let result = try Binary.readVarint32([0x05], at: 0)
        #expect(result.value == 5)
        #expect(result.next == 1)
    }

    @Test("reads a multi-byte varint32")
    func multiByte() throws {
        // 300 = 0b100101100 -> 0xac 0x02
        let result = try Binary.readVarint32([0xac, 0x02], at: 0)
        #expect(result.value == 300)
        #expect(result.next == 2)
    }

    @Test("reads a varint32 from a non-zero offset")
    func nonZeroOffset() throws {
        let result = try Binary.readVarint32([0xff, 0xac, 0x02], at: 1)
        #expect(result.value == 300)
        #expect(result.next == 3)
    }

    @Test("throws rather than returning garbage when the buffer ends mid-varint")
    func truncated() {
        #expect(throws: BinaryError.varintPastEnd("varint32 ran past end of buffer")) {
            try Binary.readVarint32([0x80], at: 0)
        }
    }

    @Test("reads a varint64 above the 32-bit range")
    func varint64() throws {
        // 2^35 = 34359738368
        let result = try Binary.readVarint64([0x80, 0x80, 0x80, 0x80, 0x80, 0x01], at: 0)
        #expect(result.value == 34_359_738_368)
        #expect(result.next == 6)
    }

    @Test("crc32c matches the standard check vector")
    func crcCheckVector() {
        // The CRC32C check value for "123456789" is 0xE3069283.
        #expect(Binary.crc32c(Array("123456789".utf8)) == 0xe306_9283)
    }

    @Test("crc round-trips through LevelDB's mask")
    func maskRoundTrip() {
        let crc = Binary.crc32c(Array("paseo".utf8))
        #expect(Binary.unmaskCrc(Binary.maskCrc(crc)) == crc)
    }

    @Test("masks the way LevelDB does, not merely in a way unmaskCrc undoes")
    func maskFormula() {
        // LevelDB: ((crc >> 15) | (crc << 17)) + 0xa282ead8, pinned as an
        // independent expression so a matching mistake in both directions
        // cannot pass the round-trip above.
        let crc: UInt32 = 0x1234_5678
        #expect(Binary.maskCrc(crc) == ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8)
    }

    @Test("compares bytes unsigned, shorter prefix first")
    func compare() {
        #expect(Binary.compare([1, 2][...], [1, 2][...]) == 0)
        #expect(Binary.compare([1][...], [1, 2][...]) < 0)
        #expect(Binary.compare([0xff][...], [0x01][...]) > 0)
        #expect(Binary.compare([][...], [0][...]) < 0)
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/SnappyTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct SnappyTests {
    @Test("decodes an empty stream")
    func empty() throws {
        #expect(try Snappy.uncompress([0x00][...]) == [])
    }

    @Test("decodes a short literal")
    func literal() throws {
        // preamble 1, literal tag (len 1), 'a'
        #expect(try Snappy.uncompress([0x01, 0x00, 0x61][...]) == Array("a".utf8))
    }

    @Test("decodes overlapping copies with a 1-byte offset, byte by byte")
    func overlappingCopy() throws {
        // 20 × 'a': literal 'a', then copy len 11 offset 1, then copy len 8 offset 1.
        let stream: [UInt8] = [0x14, 0x00, 0x61, 0x1d, 0x01, 0x11, 0x01]
        #expect(try Snappy.uncompress(stream[...]) == Array(repeating: 0x61, count: 20))
    }

    @Test("decodes copies with 2-byte and 4-byte offsets")
    func longOffsets() throws {
        // "abcd" then copy len 4 offset 4 (2-byte form), then copy len 2 offset 8 (4-byte form).
        let stream: [UInt8] = [0x0a, 0x0c, 0x61, 0x62, 0x63, 0x64, 0x0e, 0x04, 0x00, 0x07, 0x08, 0x00, 0x00, 0x00]
        #expect(try Snappy.uncompress(stream[...]) == Array("abcdabcdab".utf8))
    }

    @Test("decodes a literal longer than 60 bytes, whose length rides in trailing bytes")
    func longLiteral() throws {
        let payload = [UInt8](repeating: 0x7a, count: 100)
        // preamble 100 (varint 0x64), tag 60<<2 = 0xf0 (one trailing length byte), length-1 = 99
        let stream: [UInt8] = [0x64, 0xf0, 0x63] + payload
        #expect(try Snappy.uncompress(stream[...]) == payload)
    }

    @Test("rejects a copy that reaches before the start of the output")
    func badOffset() {
        #expect(throws: SnappyError.badOffset) {
            try Snappy.uncompress([0x04, 0x01, 0x05][...])
        }
    }

    @Test("rejects a stream whose output length does not match its preamble")
    func lengthMismatch() {
        #expect(throws: SnappyError.lengthMismatch(expected: 5, actual: 1)) {
            try Snappy.uncompress([0x05, 0x00, 0x61][...])
        }
    }

    @Test("rejects a truncated literal")
    func truncated() {
        #expect(throws: SnappyError.truncated) {
            try Snappy.uncompress([0x03, 0x08, 0x61][...])
        }
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'BinaryTests|SnappyTests'`
Expected: `Test run with 17 tests in 2 suites passed`.

- [ ] **Step 5: Mutate to prove the checksum tests bite**

Change `maskDelta` from `0xa282_ead8` to `0x1111_1111`, so mask and unmask stay each other's inverse but neither is LevelDB's. Run the filter again.

Expected: `masks the way LevelDB does, not merely in a way unmaskCrc undoes` fails, and the round-trip test still passes — which is exactly why both exist. A mutation that breaks only one direction (`&+ maskDelta` to `&+ 0`) fails both and proves nothing about their independence. Revert and confirm green.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage scripts/make-registry-fixtures.mjs
git commit -m "feat(native): LevelDB varints, CRC32C, and a snappy decoder

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The SSTable, WAL, and localStorage readers

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/SSTable.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/WAL.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/LocalStorage.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/RegistryFixtures.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/SSTableTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/WALTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/LocalStorageTests.swift`

**Ports:** `src/registry/sstable.ts`, `src/registry/wal.ts`, `src/registry/local-storage.ts` and their tests.

**Interfaces:**
- Consumes `Binary` and `Snappy` from Task 2.
- Produces `InternalRecord(userKey:sequence:isDeletion:value:)`, `SSTable.find(in:userKey:) throws -> [InternalRecord]`, `SSTableError` (with `.unsupportedCompression(UInt8)` distinguished from every other case), `LogScan(records:droppedFragments:)`, `WAL.find(in:userKey:) throws -> LogScan`, `LocalStorage.key(origin:key:)`, `LocalStorage.decodeValue(_:) throws -> String`, `LocalStorageError`.
- Test support produces `RegistryFixtures` with `registryKey`, `dir(_:)`, `names(in:suffix:)`, `tableBytes(_:)`, `logBytes(_:)`, `latin1(_:)`, `fillerKey(_:_:)`, `straddleKey`, `temporaryDirectory(_:)`, `copy(_:into:)`.

- [ ] **Step 1: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/Registry/SSTable.swift`:

```swift
import Foundation

/// One record as LevelDB stores it: a user key, the sequence number that
/// orders it against every other write, and whether it is a deletion.
public struct InternalRecord: Equatable, Sendable {
    public let userKey: [UInt8]
    public let sequence: UInt64
    public let isDeletion: Bool
    public let value: [UInt8]

    public init(userKey: [UInt8], sequence: UInt64, isDeletion: Bool, value: [UInt8]) {
        self.userKey = userKey
        self.sequence = sequence
        self.isDeletion = isDeletion
        self.value = value
    }
}

public enum SSTableError: Error, Equatable {
    case tooShort
    case badMagic
    case blockPastEnd
    /// Reading while Chromium writes: the checksum is the only thing between
    /// a torn read and silently wrong credentials.
    case checksumMismatch
    /// The compression byte is neither 0 (none) nor 1 (snappy). Distinguished
    /// from the generic parse errors so callers can tell "the storage format
    /// moved under us" apart from "this file is torn".
    case unsupportedCompression(UInt8)
    case blockTooShort
    case restartArrayOverrun
    case sharedPrefixOverrun
    case missingTrailer
    case corruptVarint

    public var message: String {
        switch self {
        case .tooShort: "file is too short to be an SSTable"
        case .badMagic: "not an SSTable: bad table magic"
        case .blockPastEnd: "block handle points past the end of the file"
        case .checksumMismatch: "LevelDB block failed its checksum"
        case .unsupportedCompression(let type):
            "Unsupported LevelDB compression type \(type). The Paseo app's storage format changed."
        case .blockTooShort: "block is too short"
        case .restartArrayOverrun: "block restart array overruns the block"
        case .sharedPrefixOverrun: "block entry shares more than it can"
        case .missingTrailer: "internal key is missing its trailer"
        case .corruptVarint: "block entry has a corrupt varint"
        }
    }
}

/// One LevelDB `.ldb`: footer, index block, data blocks, snappy.
public enum SSTable {
    private static let footerLength = 48
    private static let magicLow: UInt32 = 0x8b80_fb57
    private static let magicHigh: UInt32 = 0xdb47_7524
    private static let blockTrailerLength = 5 // 1 compression byte + 4 checksum bytes

    private struct BlockHandle {
        let offset: Int
        let size: Int
    }

    private struct BlockEntry {
        let key: [UInt8]
        let value: ArraySlice<UInt8>
    }

    /// Every record for `userKey` in one `.ldb`. Uses the index block to visit
    /// only the data blocks whose range can contain the key. A key can appear
    /// more than once with different sequence numbers, so this returns all
    /// matches and leaves the choice to the caller.
    public static func find(in file: [UInt8], userKey: [UInt8]) throws -> [InternalRecord] {
        let indexBlock = try readBlock(file, parseFooter(file))
        var found: [InternalRecord] = []

        for indexEntry in try blockEntries(indexBlock) {
            // An index entry's key is a separator >= every key in its block, so
            // a block can hold our key only if its separator is not below it.
            let separator = try splitInternalKey(indexEntry.key).userKey
            let cmp = Binary.compare(separator[...], userKey[...])
            if cmp < 0 { continue }

            let handleBytes = Array(indexEntry.value)
            let offset = try Binary.readVarint64(handleBytes, at: 0)
            let size = try Binary.readVarint64(handleBytes, at: offset.next)
            let dataBlock = try readBlock(file, BlockHandle(offset: Int(offset.value), size: Int(size.value)))

            for entry in try blockEntries(dataBlock) {
                let parsed = try splitInternalKey(entry.key)
                if Binary.compare(parsed.userKey[...], userKey[...]) != 0 { continue }
                found.append(InternalRecord(
                    userKey: parsed.userKey,
                    sequence: parsed.sequence,
                    isDeletion: parsed.isDeletion,
                    value: Array(entry.value)
                ))
            }

            // A separator strictly greater than the key means the next block
            // starts past it. An equal separator does not: a run of records
            // sharing one user key can straddle a block boundary.
            if cmp > 0 { break }
        }
        return found
    }

    private static func parseFooter(_ file: [UInt8]) throws -> BlockHandle {
        guard file.count >= footerLength else { throw SSTableError.tooShort }
        let footer = Array(file[(file.count - footerLength)...])
        guard Binary.readUInt32LE(footer, at: 40) == magicLow, Binary.readUInt32LE(footer, at: 44) == magicHigh else {
            throw SSTableError.badMagic
        }
        // metaindex handle first, then the index handle we actually want.
        var pos = 0
        pos = try Binary.readVarint64(footer, at: pos).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let offset = try Binary.readVarint64(footer, at: pos)
        let size = try Binary.readVarint64(footer, at: offset.next)
        return BlockHandle(offset: Int(offset.value), size: Int(size.value))
    }

    /// Reads one block, verifying its checksum before anything parses it.
    private static func readBlock(_ file: [UInt8], _ handle: BlockHandle) throws -> [UInt8] {
        let end = handle.offset + handle.size + blockTrailerLength
        guard handle.offset >= 0, handle.size >= 0, end <= file.count else { throw SSTableError.blockPastEnd }
        let contents = file[handle.offset..<(handle.offset + handle.size)]
        let compression = file[handle.offset + handle.size]
        let storedCrc = Binary.readUInt32LE(file, at: handle.offset + handle.size + 1)

        // The checksum covers the block contents plus the compression byte.
        let checked = file[handle.offset..<(handle.offset + handle.size + 1)]
        guard Binary.crc32c(checked) == Binary.unmaskCrc(storedCrc) else { throw SSTableError.checksumMismatch }

        switch compression {
        case 0: return Array(contents)
        case 1: return try Snappy.uncompress(contents)
        default: throw SSTableError.unsupportedCompression(compression)
        }
    }

    /// Walks a block's entries. Keys are prefix-compressed against the
    /// previous key, which is why this cannot seek and has to read forward.
    private static func blockEntries(_ block: [UInt8]) throws -> [BlockEntry] {
        guard block.count >= 4 else { throw SSTableError.blockTooShort }
        let restartCount = Int(Binary.readUInt32LE(block, at: block.count - 4))
        let entriesEnd = block.count - 4 - restartCount * 4
        guard entriesEnd >= 0 else { throw SSTableError.restartArrayOverrun }

        var entries: [BlockEntry] = []
        var pos = 0
        var previousKey: [UInt8] = []
        while pos < entriesEnd {
            let shared: (value: UInt32, next: Int)
            let nonShared: (value: UInt32, next: Int)
            let valueLength: (value: UInt32, next: Int)
            do {
                shared = try Binary.readVarint32(block, at: pos)
                nonShared = try Binary.readVarint32(block, at: shared.next)
                valueLength = try Binary.readVarint32(block, at: nonShared.next)
            } catch {
                throw SSTableError.corruptVarint
            }
            pos = valueLength.next

            guard Int(shared.value) <= previousKey.count else { throw SSTableError.sharedPrefixOverrun }
            let keyEnd = pos + Int(nonShared.value)
            let valueEnd = keyEnd + Int(valueLength.value)
            guard valueEnd <= block.count else { throw SSTableError.blockTooShort }
            var key = Array(previousKey[0..<Int(shared.value)])
            key.append(contentsOf: block[pos..<keyEnd])
            let value = block[keyEnd..<valueEnd]
            pos = valueEnd

            previousKey = key
            entries.append(BlockEntry(key: key, value: value))
        }
        return entries
    }

    /// Splits an internal key into its user key and 8-byte trailer of
    /// `(sequence << 8) | type`, stored little-endian. Type 0 is a deletion.
    private static func splitInternalKey(_ key: [UInt8]) throws -> (userKey: [UInt8], sequence: UInt64, isDeletion: Bool) {
        guard key.count >= 8 else { throw SSTableError.missingTrailer }
        let low = Binary.readUInt32LE(key, at: key.count - 8)
        let high = Binary.readUInt32LE(key, at: key.count - 4)
        // Sequence is 56 bits; the low byte of `low` is the record type.
        let sequence = (UInt64(high) << 24) | UInt64(low >> 8)
        return (Array(key[0..<(key.count - 8)]), sequence, (low & 0xff) == 0)
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/WAL.swift`:

```swift
import Foundation

/// What one `.log` yielded, and how much of it had to be thrown away.
public struct LogScan: Equatable, Sendable {
    public let records: [InternalRecord]
    /// Fragments discarded because their checksum failed, their type was not
    /// one of FULL/FIRST/MIDDLE/LAST, or their declared length ran past the
    /// block that holds them. Counted, rather than merely dropped, because a
    /// dropped fragment can be the newest write of the key we came for. A
    /// fragment abandoned at the end of the file is not counted: a log being
    /// appended to routinely ends mid-batch.
    public let droppedFragments: Int
}

/// One LevelDB `.log`: record framing and batches.
public enum WAL {
    private static let blockSize = 32768
    private static let headerSize = 7 // checksum(4) + length(2) + type(1)
    private static let typeFull: UInt8 = 1
    private static let typeFirst: UInt8 = 2
    private static let typeMiddle: UInt8 = 3
    private static let typeLast: UInt8 = 4
    private static let recordDeletion: UInt8 = 0
    private static let recordValue: UInt8 = 1

    /// Every record for `userKey` in one `.log`, plus what the log lost.
    public static func find(in file: [UInt8], userKey: [UInt8]) throws -> LogScan {
        var found: [InternalRecord] = []
        let scan = readBatches(file)
        for batch in scan.batches {
            for record in try batchRecords(batch) where Binary.compare(record.userKey[...], userKey[...]) == 0 {
                found.append(record)
            }
        }
        return LogScan(records: found, droppedFragments: scan.droppedFragments)
    }

    /// Reassembles the physical records of a write-ahead log into batch
    /// payloads. A log is a sequence of 32KB blocks, and one batch can be split
    /// across block boundaries into FIRST/MIDDLE/LAST fragments. A fragment
    /// whose checksum fails is dropped along with the batch it belongs to, and
    /// counted.
    private static func readBatches(_ file: [UInt8]) -> (batches: [[UInt8]], droppedFragments: Int) {
        var batches: [[UInt8]] = []
        var droppedFragments = 0
        var pending: [UInt8] = []
        // Once any fragment of the batch under assembly is bad, the whole
        // batch is discarded at its LAST rather than spliced with a hole.
        var pendingCorrupt = false

        var blockStart = 0
        while blockStart < file.count {
            let blockEnd = min(blockStart + blockSize, file.count)
            var pos = blockStart

            while pos + headerSize <= blockEnd {
                let length = Int(Binary.readUInt16LE(file, at: pos + 4))
                let type = file[pos + 6]
                // A run of zeroes is the block's trailing padding, not a record.
                if type == 0 && length == 0 { break }
                let payloadEnd = pos + headerSize + length
                if payloadEnd > blockEnd {
                    // At the end of the file this is the torn tail of a log
                    // still being appended to. Inside an earlier block it is a
                    // record claiming more bytes than its block holds, and the
                    // batch in progress can no longer be trusted.
                    if blockEnd != file.count {
                        droppedFragments += 1
                        pendingCorrupt = true
                    }
                    break
                }

                let storedCrc = Binary.readUInt32LE(file, at: pos)
                // The checksum covers the type byte and the payload, not the header.
                let checked = file[(pos + 6)..<payloadEnd]
                let payload = file[(pos + headerSize)..<payloadEnd]
                let intact = Binary.crc32c(checked) == Binary.unmaskCrc(storedCrc)
                let known = type == typeFull || type == typeFirst || type == typeMiddle || type == typeLast
                if !intact || !known { droppedFragments += 1 }
                pos = payloadEnd

                if !known {
                    // Taint the batch in progress rather than clearing it: a
                    // later LAST must see the taint and discard the whole batch.
                    pendingCorrupt = true
                    continue
                }

                if type == typeFull || type == typeFirst {
                    pending = []
                    pendingCorrupt = false
                }
                pending.append(contentsOf: payload)
                pendingCorrupt = pendingCorrupt || !intact
                if type == typeFull || type == typeLast {
                    if !pendingCorrupt { batches.append(pending) }
                    pending = []
                    pendingCorrupt = false
                }
            }
            blockStart += blockSize
        }
        return (batches, droppedFragments)
    }

    /// Decodes one write batch: an 8-byte base sequence, a 4-byte count, then
    /// that many records. Keys here are user keys with no trailer; a record's
    /// sequence is the batch's base plus its index.
    private static func batchRecords(_ batch: [UInt8]) throws -> [InternalRecord] {
        guard batch.count >= 12 else { return [] }
        let baseLow = UInt64(Binary.readUInt32LE(batch, at: 0))
        let baseHigh = UInt64(Binary.readUInt32LE(batch, at: 4))
        let baseSequence = (baseHigh << 32) | baseLow
        let count = Int(Binary.readUInt32LE(batch, at: 8))

        var records: [InternalRecord] = []
        var pos = 12
        var index = 0
        while index < count, pos < batch.count {
            let type = batch[pos]
            pos += 1
            let keyLength = try Binary.readVarint32(batch, at: pos)
            pos = keyLength.next
            let keyEnd = min(pos + Int(keyLength.value), batch.count)
            let userKey = Array(batch[pos..<keyEnd])
            pos = keyEnd

            var value: [UInt8] = []
            if type == recordValue {
                let valueLength = try Binary.readVarint32(batch, at: pos)
                pos = valueLength.next
                let valueEnd = min(pos + Int(valueLength.value), batch.count)
                value = Array(batch[pos..<valueEnd])
                pos = valueEnd
            } else if type != recordDeletion {
                // An unknown record type means we can no longer trust our
                // position in this batch, so stop rather than misread the rest.
                break
            }

            records.append(InternalRecord(
                userKey: userKey,
                sequence: baseSequence + UInt64(index),
                isDeletion: type == recordDeletion,
                value: value
            ))
            index += 1
        }
        return records
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/LocalStorage.swift`:

```swift
import Foundation

public enum LocalStorageError: Error, Equatable {
    case emptyValue
    case unknownEncodingTag(UInt8)
    case undecodable

    public var message: String {
        switch self {
        case .emptyValue: "localStorage value is empty"
        case .unknownEncodingTag(let tag): "Unknown localStorage value encoding tag \(tag)"
        case .undecodable: "localStorage value is not valid text"
        }
    }
}

/// Chromium's localStorage record layout, as stored in its LevelDB.
///
/// Keys and values use the same string encoding: a leading tag byte, 0x01 for
/// Latin1 when every code unit fits in a byte and 0x00 for UTF-16LE otherwise,
/// followed by the bytes. A record's key is `_<origin>` + 0x00 + the encoded
/// key; the byte after the 0x00 is the key's own encoding tag, which is why
/// an ASCII key reads as 0x00 0x01.
public enum LocalStorage {
    private static let latin1Tag: UInt8 = 0x01
    private static let utf16leTag: UInt8 = 0x00
    private static let originTerminator: UInt8 = 0x00

    public static func key(origin: String, key: String) -> [UInt8] {
        var bytes = Array("_\(origin)".utf8)
        bytes.append(originTerminator)
        bytes.append(contentsOf: encodeString(key))
        return bytes
    }

    public static func decodeValue(_ value: [UInt8]) throws -> String {
        guard let tag = value.first else { throw LocalStorageError.emptyValue }
        let body = Array(value.dropFirst())
        switch tag {
        case latin1Tag:
            guard let text = String(bytes: body, encoding: .isoLatin1) else { throw LocalStorageError.undecodable }
            return text
        case utf16leTag:
            guard let text = String(bytes: body, encoding: .utf16LittleEndian) else { throw LocalStorageError.undecodable }
            return text
        default:
            throw LocalStorageError.unknownEncodingTag(tag)
        }
    }

    private static func encodeString(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        if units.allSatisfy({ $0 <= 0xff }) {
            return [latin1Tag] + units.map { UInt8($0) }
        }
        var bytes: [UInt8] = [utf16leTag]
        for unit in units {
            bytes.append(UInt8(unit & 0xff))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }
}
```

- [ ] **Step 2: Write the fixture helper and the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/RegistryFixtures.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// The LevelDB directories `scripts/make-registry-fixtures.mjs` generates,
/// copied into the test bundle as-is.
enum RegistryFixtures {
    static let registryKey = LocalStorage.key(origin: "paseo://app", key: "@paseo:daemon-registry")

    static func dir(_ name: String) throws -> URL {
        let root = try #require(Bundle.module.resourceURL)
        return root.appendingPathComponent("Fixtures/registry/\(name)", isDirectory: true)
    }

    static func names(in dir: URL, suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// The one `.ldb` in a fixture, as bytes.
    static func tableBytes(_ name: String) throws -> [UInt8] {
        let dir = try dir(name)
        let names = try names(in: dir, suffix: ".ldb")
        #expect(names.count == 1, "expected one .ldb in \(name)")
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent(try #require(names.first))))
    }

    /// The first `.log` in a fixture, as bytes.
    static func logBytes(_ name: String) throws -> [UInt8] {
        let dir = try dir(name)
        let names = try names(in: dir, suffix: ".log")
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent(try #require(names.first))))
    }

    /// A value's text past Chromium's one-byte encoding tag, decoded as Latin1.
    static func latin1(_ value: [UInt8]) -> String {
        String(bytes: value.dropFirst(), encoding: .isoLatin1) ?? ""
    }

    /// Mirrors the generator's `fillerKey`: "0-key-*" sorts before the real
    /// registry key, "z-key-*" sorts after it.
    static func fillerKey(_ side: String, _ index: Int) -> [UInt8] {
        LocalStorage.key(origin: "paseo://app", key: "\(side)-key-\(String(format: "%04d", index))")
    }

    /// Mirrors the generator's `STRADDLE_KEY`.
    static let straddleKey = LocalStorage.key(origin: "paseo://app", key: "zz-straddle")

    /// A fresh temporary directory the test owns.
    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies every file of a fixture into `destination`.
    static func copy(_ name: String, into destination: URL) throws {
        let source = try dir(name)
        for file in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: destination.appendingPathComponent(file))
        }
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/SSTableTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct SSTableTests {
    private let key = RegistryFixtures.registryKey

    @Test("finds the record in a compacted, snappy-compressed table")
    func compacted() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("compacted"), userKey: key)
        #expect(records.count == 1)
        #expect(records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("compacted"))
    }

    @Test("returns nothing for a key the table does not hold")
    func absent() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("compacted"), userKey: Array("_nope".utf8))
        #expect(records.isEmpty)
    }

    @Test("rejects a table whose block checksum does not match")
    func corruptChecksum() throws {
        var bytes = try RegistryFixtures.tableBytes("compacted")
        // Flip a bit early in the file, inside the first data block's payload.
        bytes[64] ^= 0xff
        #expect(throws: SSTableError.checksumMismatch) {
            try SSTable.find(in: bytes, userKey: key)
        }
    }

    @Test("finds the registry key even though it is not in the first data block")
    func multiBlock() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: key)
        #expect(records.count == 1)
        #expect(records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("multi-block"))
    }

    @Test("returns nothing for a key a multi-block table does not hold")
    func multiBlockAbsent() throws {
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: Array("_nope".utf8))
        #expect(records.isEmpty)
    }

    @Test("finds a key from a later data block, exercising the index seek's skip branch")
    func laterBlock() throws {
        // The last "z-key-*" filler entry sorts well after the registry key, so
        // a correct seek has to skip past several data blocks to reach it.
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: RegistryFixtures.fillerKey("z", 199))
        #expect(records.count == 1)
        #expect(RegistryFixtures.latin1(try #require(records.first?.value)).contains("multi-block filler value 199"))
    }

    @Test("finds every version of a key whose run of internal keys straddles a block boundary")
    func straddle() throws {
        // All 10 puts survive compaction; a scan that stops at an index
        // separator equal to the target would drop the second block's versions.
        let records = try SSTable.find(in: try RegistryFixtures.tableBytes("multi-block"), userKey: RegistryFixtures.straddleKey)
        #expect(records.count == 10)
        for record in records {
            #expect(RegistryFixtures.latin1(record.value).contains("straddle version"))
        }
    }

    @Test("names an unsupported compression type rather than guessing")
    func unsupportedCompression() throws {
        var bytes = try RegistryFixtures.tableBytes("compacted")
        // Rewrite the index block's compression byte to 99 and re-checksum it,
        // so the block parses cleanly enough to reach the compression switch.
        let footer = Array(bytes[(bytes.count - 48)...])
        var pos = try Binary.readVarint64(footer, at: 0).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let indexOffset = try Binary.readVarint64(footer, at: pos)
        let indexSize = try Binary.readVarint64(footer, at: indexOffset.next)
        let compressionByte = Int(indexOffset.value + indexSize.value)
        bytes[compressionByte] = 99
        let masked = Binary.maskCrc(Binary.crc32c(bytes[Int(indexOffset.value)...compressionByte]))
        for i in 0..<4 { bytes[compressionByte + 1 + i] = UInt8((masked >> (8 * UInt32(i))) & 0xff) }
        #expect(throws: SSTableError.unsupportedCompression(99)) {
            try SSTable.find(in: bytes, userKey: key)
        }
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/WALTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// Builds synthetic `.log` bytes by hand: no fixture exercises fragmentation,
/// since every fixture payload fits one 32KB block and is written as a single
/// FULL record. The FIRST/MIDDLE/LAST reassembly path is driven directly here.
enum LogBuilder {
    static let typeFull: UInt8 = 1
    static let typeFirst: UInt8 = 2
    static let typeMiddle: UInt8 = 3
    static let typeLast: UInt8 = 4
    static let unknownType: UInt8 = 9

    static func varint(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var n = n
        while n > 0x7f {
            bytes.append(UInt8(n & 0x7f) | 0x80)
            n >>= 7
        }
        bytes.append(UInt8(n))
        return bytes
    }

    /// One logical record inside a write batch: type + key + value.
    static func writeRecord(key: [UInt8], value: [UInt8]) -> [UInt8] {
        [1] + varint(key.count) + key + varint(value.count) + value
    }

    /// A write batch: 8-byte base sequence, 4-byte count, then the records.
    static func batch(_ records: [[UInt8]]) -> [UInt8] {
        var header: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
        let count = UInt32(records.count)
        header += [UInt8(count & 0xff), UInt8((count >> 8) & 0xff), UInt8((count >> 16) & 0xff), UInt8(count >> 24)]
        return header + records.flatMap { $0 }
    }

    /// One physical log record: 4-byte masked CRC, 2-byte LE length, 1-byte
    /// type, then the payload. `corruptByte` flips a bit in the stored payload
    /// after the checksum was computed, simulating real corruption.
    static func physical(_ type: UInt8, _ payload: [UInt8], corruptByte: Int? = nil) -> [UInt8] {
        let crc = Binary.maskCrc(Binary.crc32c([type] + payload))
        var record: [UInt8] = [UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff), UInt8((crc >> 16) & 0xff), UInt8(crc >> 24)]
        record += [UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff), type]
        record += payload
        if let corruptByte { record[7 + corruptByte] ^= 0xff }
        return record
    }

    /// A header claiming `length` bytes with no payload behind it.
    static func overlongHeader(_ type: UInt8, length: Int) -> [UInt8] {
        [0, 0, 0, 0, UInt8(length & 0xff), UInt8((length >> 8) & 0xff), type]
    }

    static func splitThree(_ bytes: [UInt8]) -> ([UInt8], [UInt8], [UInt8]) {
        let third = (bytes.count + 2) / 3
        return (Array(bytes[0..<third]), Array(bytes[third..<(third * 2)]), Array(bytes[(third * 2)...]))
    }
}

struct WALTests {
    private let key = RegistryFixtures.registryKey

    @Test("finds a record written but never compacted")
    func logOnly() throws {
        let scan = try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: key)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == false)
        #expect(RegistryFixtures.latin1(try #require(scan.records.first?.value)).contains("log-only"))
    }

    @Test("reports a deletion as a deletion, not as an empty value")
    func deletion() throws {
        let scan = try WAL.find(in: try RegistryFixtures.logBytes("deleted"), userKey: key)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == true)
    }

    @Test("returns nothing for an unrelated key")
    func unrelated() throws {
        #expect(try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: Array("_nope".utf8)).records.isEmpty)
    }

    @Test("skips a record whose checksum does not match, and counts it")
    func corruptRecord() throws {
        var bytes = try RegistryFixtures.logBytes("log-only")
        // Corrupt the first record's payload, leaving its header intact.
        bytes[8] ^= 0xff
        let scan = try WAL.find(in: bytes, userKey: key)
        #expect(scan.records.isEmpty)
        #expect(scan.droppedFragments == 1)
    }

    @Test("counts nothing when the log is intact")
    func intact() throws {
        #expect(try WAL.find(in: try RegistryFixtures.logBytes("log-only"), userKey: key).droppedFragments == 0)
    }

    private let myKey = Array("mykey".utf8)
    private let myValue = Array("myvalue-that-is-reasonably-long-to-force-fragmentation".utf8)

    private func fragments() -> ([UInt8], [UInt8], [UInt8]) {
        LogBuilder.splitThree(LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: myValue)]))
    }

    @Test("reassembles a batch split across FIRST/MIDDLE/LAST")
    func reassembles() throws {
        let (f1, f2, f3) = fragments()
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeMiddle, f2) + LogBuilder.physical(LogBuilder.typeLast, f3)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.count == 1)
        #expect(scan.records.first?.isDeletion == false)
        #expect(scan.records.first?.value == myValue)
    }

    @Test("discards the whole batch when the MIDDLE fragment is corrupt")
    func corruptMiddle() throws {
        let (f1, f2, f3) = fragments()
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeMiddle, f2, corruptByte: 0) + LogBuilder.physical(LogBuilder.typeLast, f3)
        #expect(try WAL.find(in: log, userKey: myKey).records.isEmpty)
    }

    @Test("does not let a FIRST with no matching LAST leak into the next batch")
    func abandonedFirst() throws {
        let (f1, _, _) = fragments()
        let otherKey = Array("otherkey".utf8)
        let otherValue = Array("otherval".utf8)
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.typeFull, LogBuilder.batch([LogBuilder.writeRecord(key: otherKey, value: otherValue)]))
        #expect(try WAL.find(in: log, userKey: myKey).records.isEmpty)
        let scan = try WAL.find(in: log, userKey: otherKey)
        #expect(scan.records.first?.value == otherValue)
        // An abandoned FIRST is the normal shape of a log being appended to.
        #expect(scan.droppedFragments == 0)
    }

    @Test("discards the batch when a fragment in an earlier block claims more bytes than the block holds")
    func overlongInsideBlock() throws {
        let (f1, _, _) = fragments()
        let decoyBatch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: Array("decoy-carried-by-the-last-fragment".utf8))])
        let block0 = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.overlongHeader(LogBuilder.typeMiddle, length: 0x7fff)
        let log = block0 + [UInt8](repeating: 0, count: 32768 - block0.count) + LogBuilder.physical(LogBuilder.typeLast, decoyBatch)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.isEmpty)
        #expect(scan.droppedFragments == 1)
    }

    @Test("does not count a record torn at the end of the file as damage")
    func tornTail() throws {
        let batch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: Array("v".utf8))])
        let log = LogBuilder.physical(LogBuilder.typeFull, batch) + LogBuilder.overlongHeader(LogBuilder.typeFull, length: 0x7fff)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.records.count == 1)
        #expect(scan.droppedFragments == 0)
    }

    @Test("discards the batch when an unrecognized fragment type appears between FIRST and LAST")
    func unknownType() throws {
        let (f1, f2, _) = fragments()
        let decoyValue = Array("decoy-carried-by-the-last-fragment".utf8)
        let decoyBatch = LogBuilder.batch([LogBuilder.writeRecord(key: myKey, value: decoyValue)])
        let log = LogBuilder.physical(LogBuilder.typeFirst, f1) + LogBuilder.physical(LogBuilder.unknownType, f2) + LogBuilder.physical(LogBuilder.typeLast, decoyBatch)
        let scan = try WAL.find(in: log, userKey: myKey)
        #expect(scan.droppedFragments == 1)
        #expect(!scan.records.contains { $0.value == decoyValue })
        #expect(scan.records.isEmpty)
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/LocalStorageTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct LocalStorageTests {
    @Test("frames the key the way Chromium stores it")
    func framesKey() {
        let key = LocalStorage.key(origin: "paseo://app", key: "@paseo:daemon-registry")
        // 0x00 terminates the origin; 0x01 is the key's own Latin1 encoding tag.
        #expect(key == Array("_paseo://app".utf8) + [0x00, 0x01] + Array("@paseo:daemon-registry".utf8))
    }

    @Test("tags a key that does not fit in Latin1 as UTF-16LE, as Chromium does")
    func utf16Key() {
        let key = LocalStorage.key(origin: "paseo://app", key: "☕")
        #expect(key == Array("_paseo://app".utf8) + [0x00, 0x00] + [0x15, 0x26])
    }

    @Test("decodes a Latin1-tagged value")
    func latin1() throws {
        #expect(try LocalStorage.decodeValue([0x01] + Array("hosts".utf8)) == "hosts")
    }

    @Test("preserves a non-ASCII byte through the Latin1 path")
    func latin1NonAscii() throws {
        // 0xE9 is `é` in Latin1 and an invalid lead byte in UTF-8.
        #expect(try LocalStorage.decodeValue([0x01, 0x63, 0x61, 0x66, 0xe9]) == "café")
    }

    @Test("decodes a UTF-16LE-tagged value")
    func utf16() throws {
        let body = "hosts".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        #expect(try LocalStorage.decodeValue([0x00] + body) == "hosts")
    }

    @Test("preserves non-ASCII characters through the UTF-16 path")
    func utf16NonAscii() throws {
        let body = "naïve ☕".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        #expect(try LocalStorage.decodeValue([0x00] + body) == "naïve ☕")
    }

    @Test("rejects an unknown encoding tag rather than guessing")
    func unknownTag() {
        #expect(throws: LocalStorageError.unknownEncodingTag(7)) { try LocalStorage.decodeValue([0x07, 0x61]) }
    }

    @Test("rejects an empty value")
    func empty() {
        #expect(throws: LocalStorageError.emptyValue) { try LocalStorage.decodeValue([]) }
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'SSTableTests|WALTests|LocalStorageTests'`
Expected: `Test run with 27 tests in 3 suites passed`. (The review of this task added an eighth SSTable test for an oversized block handle; if you are re-running after that landed, it is 28 in 3.) If the fixture files were not copied in Task 2, every SSTable and WAL test fails on a missing resource; fix that rather than the code.

- [ ] **Step 4: Mutate to prove the straddle and taint tests bite**

Two mutations, because these are the two rules the TypeScript comments call out as bugs that were once real:

1. In `SSTable.find`, change `if cmp > 0 { break }` to `if cmp >= 0 { break }`. Expected: `finds every version of a key whose run of internal keys straddles a block boundary` fails with 6 records instead of 10. Revert.
2. In `WAL.readBatches`, in the `if !known` branch, replace `pendingCorrupt = true` with `pending = []`. Expected: `discards the batch when an unrecognized fragment type appears between FIRST and LAST` fails, because the decoy batch decodes cleanly. Revert.

Confirm green after both reverts.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): SSTable, write-ahead log, and localStorage readers

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The LevelDB directory reader

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/ErrorText.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/FileSystem.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/LevelDBReader.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/FakeFileSystem.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/LevelDBReaderTests.swift`

**Ports:** `src/registry/leveldb-reader.ts` and its test, plus `src/error-text.ts`.

**Interfaces:**
- Consumes `SSTable`, `WAL` from Task 3.
- Produces `MessageError`, `errorText(_:)`, `FileSystem` (`listDirectory(_:)`, `readFile(_:)`), `LocalFileSystem`, `FileReadError` (`.notFound` vs `.other`, the distinction the re-list rule turns on), `LevelDBReadResult(value:parseFailure:)`, `LevelDBReadError(message:cause:)`, `LevelDBReader.readValue(directory:userKey:fileSystem:)`, `LevelDBReader.maxScans`.
- Test support produces `FakeFileSystem` with `queue(_:_:)` and `readCounts`, plus `PermissionDenied`.

- [ ] **Step 1: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/ErrorText.swift`:

```swift
import Foundation

/// An error that carries the sentence the tray should show for it.
public protocol MessageError: Error {
    var message: String { get }
}

/// The message to show for a thrown value. Everything that reports a failure
/// to the user needs this, and a caught error is `any Error`, so each would
/// otherwise carry its own copy of the same narrowing.
public func errorText(_ error: any Error) -> String {
    if let error = error as? any MessageError { return error.message }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSURLErrorDomain {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

extension SSTableError: MessageError {}
extension LocalStorageError: MessageError {}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/FileSystem.swift`:

```swift
import Foundation

/// Why a file could not be read. The two cases mean different things to the
/// directory reader: a file that is gone between listing and read migrated
/// under a compaction, while anything else is damage.
public enum FileReadError: Error, MessageError {
    case notFound(path: String)
    case other(path: String, underlying: any Error)

    public var message: String {
        switch self {
        case .notFound(let path): "ENOENT: no such file, \(path)"
        case .other(let path, let underlying): "\(errorText(underlying)) (\(path))"
        }
    }
}

/// The two filesystem calls the LevelDB reader makes, injected so tests can
/// make one specific file vanish or fail between two scans.
public protocol FileSystem: Sendable {
    func listDirectory(_ path: String) throws -> [String]
    func readFile(_ path: String) throws -> [UInt8]
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func listDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func readFile(_ path: String) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached]))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                throw FileReadError.notFound(path: path)
            }
            if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               posix.domain == NSPOSIXErrorDomain, posix.code == Int(ENOENT) {
                throw FileReadError.notFound(path: path)
            }
            throw FileReadError.other(path: path, underlying: error)
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/LevelDBReader.swift`:

```swift
import Foundation

/// The value the newest surviving record carried, and whether anything in
/// the directory was unreadable while working it out. The two travel
/// together: a damaged file may have held the newest write, in which case
/// the value here is a superseded one, and the caller decides.
public struct LevelDBReadResult: Equatable, Sendable {
    /// Nil when the key is absent. Never nil alongside a `parseFailure`.
    public let value: [UInt8]?
    /// Detail for the error row when part of the database was unreadable.
    public let parseFailure: String?
}

/// "No value" plus trouble: absence is indistinguishable from a file that
/// could not be read or was never seen, so the read fails rather than
/// reporting the key as gone.
public struct LevelDBReadError: MessageError {
    public let message: String
    public let cause: (any Error)?
}

/// A LevelDB directory: newest sequence wins. Reads one key without taking
/// the database lock, scanning every `.ldb`/`.sst`/`.log` and taking the
/// highest sequence, which is correct by construction provided the scan saw
/// every live file; re-listing when a file vanished is what guarantees that.
public enum LevelDBReader {
    /// How many times one read may list the directory. Chromium can compact
    /// more than once while we work.
    static let maxScans = 3

    private struct ScanResult {
        var winner: InternalRecord?
        var relevantCount = 0
        var parseSkipCount = 0
        var vanishedCount = 0
        var firstParseError: (any Error)?
    }

    public static func readValue(directory: String, userKey: [UInt8], fileSystem: any FileSystem = LocalFileSystem()) throws -> LevelDBReadResult {
        var result = try scan(directory, userKey, fileSystem)
        var scans = 1
        while scans < maxScans, result.vanishedCount > 0 {
            result = try scan(directory, userKey, fileSystem)
            scans += 1
        }

        let value: [UInt8]? = if let winner = result.winner, !winner.isDeletion { winner.value } else { nil }

        let damaged = result.parseSkipCount > 0
        let unsettled = result.vanishedCount > 0
        if damaged || unsettled {
            let detail = damaged
                ? "Could not read \(result.parseSkipCount) of \(result.relevantCount) LevelDB file(s) in \(directory)"
                : "\(directory) kept changing across \(maxScans) listings"
            guard let value else {
                throw LevelDBReadError(message: "\(detail); the key's value could not be determined", cause: result.firstParseError)
            }
            return LevelDBReadResult(value: value, parseFailure: "\(detail); the host list may be out of date")
        }
        return LevelDBReadResult(value: value, parseFailure: nil)
    }

    /// One pass: list the directory and best-effort read every table and log
    /// in that listing. A file gone by read time (`notFound`) means the
    /// listing was stale; any other read error, or a parse error, is damage.
    /// An unsupported compression type means the format moved under us and
    /// every file is suspect, so that one propagates.
    private static func scan(_ directory: String, _ userKey: [UInt8], _ fileSystem: any FileSystem) throws -> ScanResult {
        let names = try fileSystem.listDirectory(directory)
        var result = ScanResult()

        for name in names {
            // `.sst` is LevelDB's pre-2013 name for the same table format.
            let isTable = name.hasSuffix(".ldb") || name.hasSuffix(".sst")
            let isLog = name.hasSuffix(".log")
            guard isTable || isLog else { continue }
            result.relevantCount += 1

            let bytes: [UInt8]
            do {
                bytes = try fileSystem.readFile((directory as NSString).appendingPathComponent(name))
            } catch FileReadError.notFound {
                result.vanishedCount += 1
                continue
            } catch {
                result.parseSkipCount += 1
                if result.firstParseError == nil { result.firstParseError = error }
                continue
            }

            let records: [InternalRecord]
            do {
                if isTable {
                    records = try SSTable.find(in: bytes, userKey: userKey)
                } else {
                    let log = try WAL.find(in: bytes, userKey: userKey)
                    records = log.records
                    if log.droppedFragments > 0 {
                        result.parseSkipCount += 1
                        if result.firstParseError == nil {
                            result.firstParseError = LevelDBReadError(
                                message: "Discarded \(log.droppedFragments) corrupt record fragment(s) in \(name)",
                                cause: nil
                            )
                        }
                    }
                }
            } catch SSTableError.unsupportedCompression(let type) {
                throw SSTableError.unsupportedCompression(type)
            } catch {
                result.parseSkipCount += 1
                if result.firstParseError == nil { result.firstParseError = error }
                continue
            }

            for record in records where result.winner == nil || record.sequence > result.winner!.sequence {
                result.winner = record
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Write the fake filesystem and the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/FakeFileSystem.swift`:

```swift
import Foundation
@testable import PaseoIconCore

/// A filesystem that passes through to the real one except for paths a test
/// has queued behaviours for. Each path's queue is consumed front to back and
/// then sticks on its last entry, so "throw once, then succeed" and "always
/// throw" are both expressible. This is the seam a test uses to make one
/// specific file vanish between the two scans `readValue` can run.
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    enum Behavior {
        case vanish
        case fail(any Error)
        case bytes([UInt8])
    }

    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var queues: [String: [Behavior]] = [:]
    private(set) var readCounts: [String: Int] = [:]

    func queue(_ path: String, _ behaviors: [Behavior]) {
        lock.lock()
        defer { lock.unlock() }
        queues[path] = behaviors
    }

    func listDirectory(_ path: String) throws -> [String] {
        try real.listDirectory(path)
    }

    func readFile(_ path: String) throws -> [UInt8] {
        lock.lock()
        readCounts[path, default: 0] += 1
        var behavior: Behavior?
        if var queue = queues[path], !queue.isEmpty {
            behavior = queue.count > 1 ? queue.removeFirst() : queue[0]
            queues[path] = queue
        }
        lock.unlock()

        switch behavior {
        case .vanish: throw FileReadError.notFound(path: path)
        case .fail(let error): throw FileReadError.other(path: path, underlying: error)
        case .bytes(let bytes): return bytes
        case nil: return try real.readFile(path)
        }
    }
}

/// A POSIX error that is not ENOENT, for the "damage, not migration" case.
struct PermissionDenied: Error, CustomStringConvertible {
    var description: String { "EACCES" }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/LevelDBReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct LevelDBReaderTests {
    private let key = RegistryFixtures.registryKey

    private func text(_ value: [UInt8]?) throws -> String {
        RegistryFixtures.latin1(try #require(value))
    }

    /// The value alone, asserting the read reported no damage along the way.
    private func cleanValue(_ dir: URL, _ key: [UInt8], fileSystem: any FileSystem = LocalFileSystem()) throws -> String {
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fileSystem)
        #expect(result.parseFailure == nil)
        return try text(result.value)
    }

    /// A copy of a fixture with one file's bytes rewritten on disk.
    private func copyFixture(_ name: String, corrupting suffix: String? = nil, at byte: Int = 64) throws -> URL {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader")
        try RegistryFixtures.copy(name, into: dir)
        if let suffix {
            let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: suffix).first))
            var bytes = [UInt8](try Data(contentsOf: target))
            bytes[byte] ^= 0xff
            try Data(bytes).write(to: target)
        }
        return dir
    }

    /// A fresh directory holding only the fixture's `.ldb`.
    private func onlyTable(_ name: String, corrupt: Bool = false) throws -> URL {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-table")
        let source = try RegistryFixtures.dir(name)
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        var bytes = [UInt8](try Data(contentsOf: source.appendingPathComponent(file)))
        if corrupt { bytes[64] ^= 0xff }
        try Data(bytes).write(to: dir.appendingPathComponent(file))
        return dir
    }

    @Test("reads a value that lives only in the log")
    func logOnly() throws {
        #expect(try cleanValue(try RegistryFixtures.dir("log-only"), key).contains("log-only"))
    }

    @Test("reads a value that lives in a compacted table")
    func compacted() throws {
        #expect(try cleanValue(try RegistryFixtures.dir("compacted"), key).contains("compacted"))
    }

    @Test("prefers the newer log write over the older compacted value")
    func superseded() throws {
        let value = try cleanValue(try RegistryFixtures.dir("superseded"), key)
        #expect(value.contains("fresh"))
        #expect(!value.contains("stale"))
    }

    @Test("returns nil when the newest record is a deletion")
    func deletion() throws {
        let result = try LevelDBReader.readValue(directory: try RegistryFixtures.dir("deleted").path, userKey: key)
        #expect(result.value == nil)
    }

    @Test("returns nil for a key that was never written")
    func absent() throws {
        let result = try LevelDBReader.readValue(directory: try RegistryFixtures.dir("compacted").path, userKey: Array("_missing".utf8))
        #expect(result.value == nil)
    }

    @Test("rejects a directory that does not exist")
    func missingDirectory() throws {
        #expect(throws: (any Error).self) {
            try LevelDBReader.readValue(directory: "/nope/not/here", userKey: key)
        }
    }

    @Test("throws, rather than returning nil, when every file that could hold the key fails to parse")
    func allCorrupt() throws {
        let dir = try onlyTable("compacted", corrupt: true)
        var caught: (any Error)?
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        } catch {
            caught = error
        }
        // Names how many files were skipped: a parse failure must route to
        // "keep last known-good hosts", not to the "key absent" nil.
        let error = try #require(caught as? LevelDBReadError)
        #expect(error.message.contains("1 of 1"))
        #expect(error.cause != nil)
    }

    @Test("still returns the good record when a sibling file is corrupt")
    func corruptSibling() throws {
        // The corrupted file is the .ldb holding the stale value; the .log's
        // fresh value must still win.
        let dir = try copyFixture("superseded", corrupting: ".ldb")
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        #expect(try text(result.value).contains("fresh"))
        #expect(try #require(result.parseFailure).contains("1 of 2"))
    }

    @Test("reports the damage when the torn file was the one holding the newest value")
    func tornNewestFile() throws {
        // The `.log` held `fresh`; only `stale` survives. Returning it is
        // right; returning it silently is what let a deleted host linger.
        let dir = try copyFixture("superseded", corrupting: ".log", at: 8)
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        #expect(try text(result.value).contains("stale"))
        #expect(try #require(result.parseFailure).contains("1 of 2"))
        #expect(try #require(result.parseFailure).contains("out of date"))
    }

    @Test("treats a deletion found next to an unreadable file as undetermined, not as an absent key")
    func deletionNextToDamage() throws {
        let dir = try copyFixture("deleted", corrupting: ".ldb")
        #expect(throws: LevelDBReadError.self) {
            try LevelDBReader.readValue(directory: dir.path, userKey: key)
        }
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
        }
    }

    @Test("scans a table named with the legacy .sst extension")
    func legacyExtension() throws {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-sst")
        let source = try RegistryFixtures.dir("compacted")
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: dir.appendingPathComponent("000005.sst"))
        #expect(try cleanValue(dir, key).contains("compacted"))
    }

    @Test("propagates an unsupported compression type instead of treating it as a skippable parse failure")
    func unsupportedCompression() throws {
        // Rewrite the index block's compression byte and re-checksum, so the
        // block parses cleanly enough to reach the compression switch.
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-codec")
        let source = try RegistryFixtures.dir("compacted")
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        var bytes = [UInt8](try Data(contentsOf: source.appendingPathComponent(file)))
        let footer = Array(bytes[(bytes.count - 48)...])
        var pos = try Binary.readVarint64(footer, at: 0).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let indexOffset = try Binary.readVarint64(footer, at: pos)
        let indexSize = try Binary.readVarint64(footer, at: indexOffset.next)
        let compressionByte = Int(indexOffset.value + indexSize.value)
        bytes[compressionByte] = 99
        let masked = Binary.maskCrc(Binary.crc32c(bytes[Int(indexOffset.value)...compressionByte]))
        for i in 0..<4 { bytes[compressionByte + 1 + i] = UInt8((masked >> (8 * UInt32(i))) & 0xff) }
        try Data(bytes).write(to: dir.appendingPathComponent(file))

        #expect(throws: SSTableError.unsupportedCompression(99)) {
            try LevelDBReader.readValue(directory: dir.path, userKey: key)
        }
    }

    @Test("reports the key as undetermined, not absent, when the only relevant file keeps vanishing")
    func alwaysVanishes() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish])

        // The listing named a file that could hold the key and we never got to
        // read it. "Absent" would send the tray to zero hosts.
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
            Issue.record("expected readValue to throw")
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
        }
        #expect(fs.readCounts[target] == LevelDBReader.maxScans)
    }

    @Test("returns the good record with a warning when a sibling file keeps vanishing")
    func siblingVanishes() throws {
        let dir = try copyFixture("superseded")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish])

        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
        #expect(try text(result.value).contains("fresh"))
        #expect(try #require(result.parseFailure).contains("out of date"))
    }

    @Test("lists again when the newer file vanished, instead of returning the older survivor as current")
    func relistsAfterVanish() throws {
        // The .log holds `fresh`, the .ldb holds `stale`. The .log vanishes on
        // the first read only: a reader that only re-lists when it found
        // nothing would hand back `stale` with no signal.
        let dir = try copyFixture("superseded")
        let logPath = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".log").first)).path
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: logPath)))
        let fs = FakeFileSystem()
        fs.queue(logPath, [.vanish, .bytes(good)])

        #expect(try cleanValue(dir, key, fileSystem: fs).contains("fresh"))
    }

    @Test("treats a read error other than ENOENT as damage, not as a vanished file")
    func permissionDenied() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.fail(PermissionDenied())])

        // A file we were refused says nothing about where its data went.
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
            Issue.record("expected readValue to throw")
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
            #expect(errorText(try #require(error.cause)).contains("EACCES"))
        }
        // Damage is not a stale listing, so it must not trigger a re-list.
        #expect(fs.readCounts[target] == 1)
    }

    @Test("finds the record on the retried scan after the first scan saw the file vanish")
    func retrySucceeds() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: target)))
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish, .bytes(good)])

        #expect(try cleanValue(dir, key, fileSystem: fs).contains("compacted"))
        #expect(fs.readCounts[target] == 2)
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter LevelDBReaderTests`
Expected: `Test run with 17 tests in 1 suite passed`, the same 17 the TypeScript suite has.

- [ ] **Step 4: Mutate to prove the ENOENT distinction bites**

In `LevelDBReader.scan`, change `catch FileReadError.notFound` to also catch everything (delete the specific catch and let the general one handle both). Run the filter.
Expected: `treats a read error other than ENOENT as damage, not as a vanished file` fails. Revert.

Then the opposite: change the general `catch` to increment `vanishedCount` instead of `parseSkipCount`. Expected: the same test fails on the read count. Revert and confirm green.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): LevelDB directory reader, newest sequence wins

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Config validation and the registry parser

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Config/AppConfig.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/PaseoRegistry.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/PaseoRegistryTests.swift`

**Ports:** `src/registry/paseo-registry.ts` and its test, plus the `AppConfigSchema` and `hostsFingerprint` halves of `src/config/host-entry.ts`.

**Deliberate difference:** the TypeScript validates with zod. Swift has no schema library here, so `AppConfig.validate` and the profile parser hand-roll the same rules and produce the same messages. The rules are: duplicate ids rejected, empty labels rejected, relay offers validated, one bad profile named and skipped, a non-array record failing the whole read, and a connection kind the tray has never seen reducing to "no connection the menu bar can use".

**Interfaces:**
- Consumes `LevelDBReader`, `LocalStorage`, `HostEntry`, `ConnectionOffer`.
- Produces `AppConfig` (`.validate(hosts:) throws`, `.unvalidated(hosts:)`, `.hosts`), `AppConfigError`, `hostsFingerprint(_:)`, `HostEntry: Codable`, `ConnectionOfferError.message`, `RegistrySnapshot(hosts:failures:warning:)`, `RegistryError`, `PaseoRegistry.levelDbDir(appSupportDir:)`, `PaseoRegistry.read(appSupportDir:fileSystem:)`, `PaseoRegistry.hostEntries(fromJSON:)`.

- [ ] **Step 1: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/Config/AppConfig.swift`:

```swift
import Foundation

/// The host set the fleet is built from. Only the registry session builds
/// one, and only through `validate`, which is what makes the fleet's
/// duplicate-id invariant hold.
public struct AppConfig: Equatable, Sendable {
    public let version = 1
    public let hosts: [HostEntry]

    /// Duplicate ids and empty offer fields are rejected with a message per
    /// issue, the way the published schemas rejected them.
    public static func validate(hosts: [HostEntry]) throws -> AppConfig {
        var issues: [String] = []
        var seen = Set<String>()
        for entry in hosts {
            if seen.contains(entry.id) {
                issues.append("Duplicate host id \"\(entry.id)\". Each host needs its own id.")
            }
            seen.insert(entry.id)
            if let label = entry.label, label.isEmpty {
                issues.append("Host \(entry.id): label must not be empty when present.")
            }
            if case .relay(_, _, let offer) = entry {
                do {
                    _ = try offer.validated()
                } catch let error as ConnectionOfferError {
                    issues.append("Host \(entry.id): \(error.message)")
                }
            }
        }
        guard issues.isEmpty else { throw AppConfigError(issues: issues) }
        return AppConfig(hosts: hosts)
    }

    /// A config that skipped validation. Nothing in the app builds one this
    /// way: the fleet's duplicate-id guard is the last line of defence for a
    /// call site that does, and this is how that guard is tested.
    public static func unvalidated(hosts: [HostEntry]) -> AppConfig {
        AppConfig(hosts: hosts)
    }

    private init(hosts: [HostEntry]) {
        self.hosts = hosts
    }
}

public struct AppConfigError: MessageError, Equatable {
    public let issues: [String]
    public var message: String { issues.joined(separator: "\n") }
}

extension ConnectionOfferError {
    public var message: String {
        switch self {
        case .missingFragment: "no #offer= fragment"
        case .invalidBase64: "the offer is not base64"
        case .invalidJSON(let detail): "the offer is not valid JSON (\(detail))"
        case .unsupportedVersion(let version): "unsupported offer version \(version)"
        case .emptyField(let field): "\(field) must not be empty"
        }
    }
}

/// Stable identity of a host list, used to tell a real change in the Paseo
/// app's registry apart from Chromium rewriting its database for keys the
/// tray does not care about. Ids are unique, so sorting by id is a total
/// order, and keys are sorted so the same host serializes one way.
public func hostsFingerprint(_ hosts: [HostEntry]) -> String {
    let ordered = hosts.sorted { $0.id < $1.id }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(ordered) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

extension HostEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, label, type, endpoint, useTls, password, offer }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(label, forKey: .label)
        switch self {
        case .directTcp(_, _, let endpoint, let useTls, let password):
            try container.encode("directTcp", forKey: .type)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(useTls, forKey: .useTls)
            try container.encodeIfPresent(password, forKey: .password)
        case .relay(_, _, let offer):
            try container.encode("relay", forKey: .type)
            try container.encode(offer, forKey: .offer)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        switch try container.decode(String.self, forKey: .type) {
        case "directTcp":
            self = .directTcp(
                id: id,
                label: label,
                endpoint: try container.decode(String.self, forKey: .endpoint),
                useTls: try container.decodeIfPresent(Bool.self, forKey: .useTls) ?? false,
                password: try container.decodeIfPresent(String.self, forKey: .password)
            )
        case "relay":
            self = .relay(id: id, label: label, offer: try container.decode(ConnectionOffer.self, forKey: .offer))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown host type \(other)")
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/PaseoRegistry.swift`:

```swift
import Foundation

/// The hosts the Paseo desktop app has stored, as the tray can use them.
public struct RegistrySnapshot: Equatable, Sendable {
    public var hosts: [HostEntry]
    /// Hosts the tray cannot dial, phrased for the error row. Never silent.
    public var failures: [String]
    /// Set when the hosts above were read out of a database that was partly
    /// unreadable, so they may be superseded.
    public var warning: String?

    public init(hosts: [HostEntry], failures: [String], warning: String? = nil) {
        self.hosts = hosts
        self.failures = failures
        self.warning = warning
    }
}

public enum RegistryError: MessageError, Equatable {
    case notAnArray
    case invalidJSON(String)
    case appNotFound(dir: String)
    case storageUnreachable(dir: String, detail: String)

    public var message: String {
        switch self {
        case .notAnArray: "The registry record is not an array of profiles"
        case .invalidJSON(let detail): "The registry record is not valid JSON: \(detail)"
        case .appNotFound(let dir): "Paseo desktop app not found.\n\nLooked in:\n\(dir)"
        case .storageUnreachable(let dir, let detail): "Could not open the Paseo app's storage at \(dir): \(detail)"
        }
    }
}

/// Reads the Paseo desktop app's host registry out of its Chromium
/// localStorage. An unsupported surface: nothing upstream promises the
/// location, the key, or the value encoding. The payload's shape is the
/// published connection schemas, and that part is safe.
public enum PaseoRegistry {
    public static let origin = "paseo://app"
    public static let registryKey = "@paseo:daemon-registry"
    /// The shipped app's support directory. A development build loads from
    /// the dev server and keys its storage under another origin, so it is
    /// deliberately not probed.
    static let appDirectory = "Paseo"
    static let localStorageSubpath = "Local Storage/leveldb"
    static let knownConnectionTypes: Set<String> = ["directTcp", "relay", "directSocket", "directPipe"]

    /// The leveldb directory of the installed Paseo app. Absent is a distinct,
    /// actionable state ("the app is not installed"); any other reason it
    /// cannot be reached is reported with its own error.
    public static func levelDbDir(appSupportDir: String) throws -> String {
        let dir = (appSupportDir as NSString).appendingPathComponent(appDirectory) + "/" + localStorageSubpath
        if access(dir, F_OK) == 0 { return dir }
        let code = errno
        if code == ENOENT { throw RegistryError.appNotFound(dir: dir) }
        let detail = "\(String(cString: strerror(code))) (\(posixName(code)))"
        throw RegistryError.storageUnreachable(dir: dir, detail: detail)
    }

    /// Nil means the app is installed but has never stored a registry.
    public static func read(appSupportDir: String, fileSystem: any FileSystem = LocalFileSystem()) throws -> RegistrySnapshot? {
        let dir = try levelDbDir(appSupportDir: appSupportDir)
        let result = try LevelDBReader.readValue(directory: dir, userKey: LocalStorage.key(origin: origin, key: registryKey), fileSystem: fileSystem)
        guard let value = result.value else { return nil }
        var snapshot = try hostEntries(fromJSON: try LocalStorage.decodeValue(value))
        // A value found next to an unreadable file is usable but not the last word.
        snapshot.warning = result.parseFailure
        return snapshot
    }

    /// Maps the stored profiles to host entries. Anything but an array fails
    /// the whole read; one profile that does not parse is named and skipped,
    /// because losing the others over a sibling is the silent cap this
    /// project forbids.
    public static func hostEntries(fromJSON json: String) throws -> RegistrySnapshot {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw RegistryError.invalidJSON(errorText(error))
        }
        guard let candidates = parsed as? [Any] else { throw RegistryError.notAnArray }

        var hosts: [HostEntry] = []
        var failures: [String] = []
        var seenServerIds = Set<String>()

        for (index, candidate) in candidates.enumerated() {
            let name = describeProfile(candidate, index: index)
            let profile: Profile
            do {
                profile = try Profile(candidate)
            } catch let error as ProfileError {
                failures.append("\(name) — could not be read (\(error.issues.joined(separator: "; ")))")
                continue
            }

            guard let connection = profile.chooseConnection() else {
                let kinds = profile.connections.map(\.type)
                let has = kinds.isEmpty ? "" : " (has: \(kinds.joined(separator: ", ")))"
                failures.append("\(name) — no connection the menu bar can use\(has)")
                continue
            }

            // Two profiles for one daemon: the id keys the fleet's connection
            // map, so the first wins and the second is named.
            if seenServerIds.contains(profile.serverId) {
                failures.append("\(name) — a second profile for host \(profile.serverId); the menu bar shows the first")
                continue
            }
            seenServerIds.insert(profile.serverId)

            // The id is the serverId, never the connection id: distinct hosts
            // share the identical relay connection id. An empty label is left
            // out rather than carried through.
            let label = profile.label.flatMap { $0.isEmpty ? nil : $0 }
            switch connection {
            case .directTcp(let endpoint, let useTls, let password):
                hosts.append(.directTcp(id: profile.serverId, label: label, endpoint: endpoint, useTls: useTls, password: password))
            case .relay(let endpoint, let useTls, let daemonPublicKeyB64):
                hosts.append(.relay(
                    id: profile.serverId,
                    label: label,
                    offer: ConnectionOffer(serverId: profile.serverId, daemonPublicKeyB64: daemonPublicKeyB64, relay: .init(endpoint: endpoint, useTls: useTls))
                ))
            }
        }
        return RegistrySnapshot(hosts: hosts, failures: failures)
    }

    // MARK: - Profile parsing

    private struct ProfileError: Error {
        let issues: [String]
    }

    private enum Dialable {
        case directTcp(endpoint: String, useTls: Bool, password: String?)
        case relay(endpoint: String, useTls: Bool?, daemonPublicKeyB64: String)
    }

    private struct Connection {
        let id: String?
        let type: String
        let dialable: Dialable?
    }

    /// One stored profile, validated the way the published schemas validated
    /// it: a known connection kind with a malformed shape is an issue, an
    /// unknown kind is merely unusable.
    private struct Profile {
        let serverId: String
        let label: String?
        let connections: [Connection]
        let preferredConnectionId: String?

        init(_ candidate: Any) throws {
            guard let object = candidate as? [String: Any] else { throw ProfileError(issues: ["profile: expected an object"]) }
            var issues: [String] = []

            var serverId = ""
            if let raw = object["serverId"] as? String {
                serverId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if serverId.isEmpty { issues.append("serverId: must not be empty") }
            } else {
                issues.append("serverId: required")
            }

            var label: String?
            if let raw = object["label"] {
                if let text = raw as? String { label = text } else if !(raw is NSNull) { issues.append("label: expected a string") }
            }

            var connections: [Connection] = []
            if let rawConnections = object["connections"] as? [Any] {
                for (index, raw) in rawConnections.enumerated() {
                    guard let entry = raw as? [String: Any], let type = entry["type"] as? String else {
                        issues.append("connections.\(index): expected an object with a type")
                        continue
                    }
                    let id = entry["id"] as? String
                    let prefix = "connections.\(index)"
                    switch type {
                    case "directTcp":
                        guard let endpoint = entry["endpoint"] as? String else { issues.append("\(prefix).endpoint: required"); continue }
                        var useTls = false
                        if let raw = entry["useTls"] { if let flag = raw as? Bool { useTls = flag } else { issues.append("\(prefix).useTls: expected a boolean"); continue } }
                        var password: String?
                        if let raw = entry["password"] { if let text = raw as? String { password = text } else { issues.append("\(prefix).password: expected a string"); continue } }
                        connections.append(Connection(id: id, type: type, dialable: .directTcp(endpoint: endpoint, useTls: useTls, password: password)))
                    case "relay":
                        guard let endpoint = entry["relayEndpoint"] as? String else { issues.append("\(prefix).relayEndpoint: required"); continue }
                        guard let key = entry["daemonPublicKeyB64"] as? String else { issues.append("\(prefix).daemonPublicKeyB64: required"); continue }
                        var useTls: Bool?
                        if let raw = entry["useTls"] { if let flag = raw as? Bool { useTls = flag } else { issues.append("\(prefix).useTls: expected a boolean"); continue } }
                        connections.append(Connection(id: id, type: type, dialable: .relay(endpoint: endpoint, useTls: useTls, daemonPublicKeyB64: key)))
                    case "directSocket", "directPipe":
                        guard entry["path"] is String else { issues.append("\(prefix).path: required"); continue }
                        connections.append(Connection(id: id, type: type, dialable: nil))
                    default:
                        // A kind the tray has never seen reduces to "unusable", not to a rejected profile.
                        connections.append(Connection(id: id, type: type, dialable: nil))
                    }
                }
            } else {
                issues.append("connections: required")
            }

            var preferred: String?
            if let raw = object["preferredConnectionId"] {
                if let text = raw as? String { preferred = text } else if !(raw is NSNull) { issues.append("preferredConnectionId: expected a string") }
            }

            guard issues.isEmpty else { throw ProfileError(issues: issues) }
            self.serverId = serverId
            self.label = label
            self.connections = connections
            self.preferredConnectionId = preferred
        }

        /// The profile's preference when the tray supports it, else the first
        /// supported one.
        func chooseConnection() -> Dialable? {
            let supported = connections.filter { $0.dialable != nil }
            if let preferred = supported.first(where: { $0.id != nil && $0.id == preferredConnectionId }) { return preferred.dialable }
            return supported.first?.dialable
        }
    }

    /// The best name for a profile that may not have parsed: label, serverId,
    /// else its position.
    private static func describeProfile(_ candidate: Any, index: Int) -> String {
        if let object = candidate as? [String: Any] {
            if let label = object["label"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
            if let serverId = object["serverId"] as? String, !serverId.trimmingCharacters(in: .whitespaces).isEmpty { return serverId }
        }
        return "profile \(index + 1)"
    }

    private static func posixName(_ code: Int32) -> String {
        switch code {
        case ENOTDIR: "ENOTDIR"
        case EACCES: "EACCES"
        case ELOOP: "ELOOP"
        default: "errno \(code)"
        }
    }
}
```

- [ ] **Step 2: Write the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/PaseoRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct PaseoRegistryTests {
    /// The stored profile shape, with overrides, serialized the way the Paseo
    /// app stores it.
    private func profile(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "serverId": "srv_one",
            "label": "Mac.localdomain",
            "lifecycle": [:],
            "connections": [["id": "direct:localhost:6767", "type": "directTcp", "endpoint": "localhost:6767"]],
            "preferredConnectionId": "direct:localhost:6767",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "updatedAt": "2026-01-01T00:00:00.000Z",
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    private func json(_ profiles: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: profiles), as: UTF8.self)
    }

    @Test("maps a direct TCP host, keying it by serverId")
    func directHost() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile()]))
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.hosts == [.directTcp(id: "srv_one", label: "Mac.localdomain", endpoint: "localhost:6767", useTls: false, password: nil)])
    }

    @Test("rebuilds a relay offer from the stored connection")
    func relayHost() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "serverId": "srv_two",
            "label": "ai-mbp.local",
            "connections": [[
                "id": "relay:wss:relay.paseo.sh:443",
                "type": "relay",
                "relayEndpoint": "relay.paseo.sh:443",
                "useTls": true,
                "daemonPublicKeyB64": "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
            ]],
            "preferredConnectionId": "relay:wss:relay.paseo.sh:443",
        ])]))
        #expect(snapshot.hosts.first == .relay(
            id: "srv_two",
            label: "ai-mbp.local",
            offer: ConnectionOffer(
                serverId: "srv_two",
                daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
                relay: .init(endpoint: "relay.paseo.sh:443", useTls: true)
            )
        ))
    }

    @Test("keeps two relay hosts apart even though their connection ids are identical")
    func sharedConnectionId() throws {
        let shared: [String: Any] = [
            "id": "relay:wss:relay.paseo.sh:443",
            "type": "relay",
            "relayEndpoint": "relay.paseo.sh:443",
            "useTls": true,
            "daemonPublicKeyB64": "AAAA",
        ]
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_a", "connections": [shared], "preferredConnectionId": shared["id"] as Any]),
            profile(["serverId": "srv_b", "connections": [shared], "preferredConnectionId": shared["id"] as Any]),
        ]))
        #expect(snapshot.hosts.map(\.id) == ["srv_a", "srv_b"])
    }

    @Test("keeps only the first profile for a repeated serverId and names the loser")
    func duplicateServerId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["label": "Direct one"]),
            profile([
                "label": "Relay twin",
                "connections": [["id": "relay:wss:relay.paseo.sh:443", "type": "relay", "relayEndpoint": "relay.paseo.sh:443", "useTls": true, "daemonPublicKeyB64": "AAAA"]],
                "preferredConnectionId": "relay:wss:relay.paseo.sh:443",
            ]),
        ]))
        // The id keys the fleet's connection map, so admitting both leaves one
        // live socket labelled and typed as the other.
        #expect(snapshot.hosts.count == 1)
        #expect(snapshot.hosts.first?.id == "srv_one")
        #expect(snapshot.hosts.first?.label == "Direct one")
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Relay twin"))
        #expect(try #require(snapshot.failures.first).contains("srv_one"))
    }

    @Test("falls back to a supported connection when the preferred one is not")
    func unsupportedPreference() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [
                ["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"],
                ["id": "direct:1", "type": "directTcp", "endpoint": "10.0.0.9:6767"],
            ],
            "preferredConnectionId": "pipe:1",
        ])]))
        #expect(snapshot.hosts.count == 1)
        if case .directTcp(_, _, let endpoint, _, _) = try #require(snapshot.hosts.first) {
            #expect(endpoint == "10.0.0.9:6767")
        } else {
            Issue.record("expected a direct host")
        }
    }

    @Test("drops a host with no supported connection and names it in failures")
    func noSupportedConnection() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "label": "Pipe only",
            "connections": [["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"]],
            "preferredConnectionId": "pipe:1",
        ])]))
        #expect(snapshot.hosts.isEmpty)
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Pipe only"))
    }

    @Test("carries a direct host's password through")
    func password() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [["id": "d", "type": "directTcp", "endpoint": "10.0.0.9:6767", "useTls": true, "password": "hunter2"]],
            "preferredConnectionId": "d",
        ])]))
        if case .directTcp(_, _, _, let useTls, let password) = try #require(snapshot.hosts.first) {
            #expect(useTls)
            #expect(password == "hunter2")
        } else {
            Issue.record("expected a direct host")
        }
    }

    @Test("keeps every other host when one profile carries a connection type the tray has never seen")
    func unknownConnectionType() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_known"]),
            profile([
                "serverId": "srv_future",
                "label": "Future",
                "connections": [["id": "ws:1", "type": "directWs", "url": "ws://x"]],
                "preferredConnectionId": "ws:1",
            ]),
        ]))
        // The desktop app is not version-pinned: a connection kind it adds
        // tomorrow must cost that one host, named, and nothing else.
        #expect(snapshot.hosts.map(\.id) == ["srv_known"])
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Future"))
        #expect(try #require(snapshot.failures.first).contains("directWs"))
    }

    @Test("names a profile that does not parse and keeps the rest")
    func malformedProfile() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_ok"]),
            profile(["serverId": "srv_bad", "label": "Broken", "connections": [["id": "d", "type": "directTcp"]]]),
            ["nothing": true],
        ]))
        #expect(snapshot.hosts.map(\.id) == ["srv_ok"])
        #expect(snapshot.failures.count == 2)
        // A known kind with a malformed shape is a profile-level failure that
        // says what was missing.
        #expect(try #require(snapshot.failures.first).contains("Broken"))
        #expect(try #require(snapshot.failures.first).contains("endpoint"))
        // With nothing to name it by, the row falls back to the position.
        #expect(snapshot.failures[1].contains("profile 3"))
    }

    @Test("trims a serverId the way the Paseo app does before using it as the host id")
    func trimsServerId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile(["serverId": "  srv_pad  "])]))
        // For a relay host this string is sent as the session id, so a stray
        // space is a host that never connects.
        #expect(snapshot.hosts.first?.id == "srv_pad")
    }

    @Test("accepts a connection without an id, as the app's own schema does")
    func connectionWithoutId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [["type": "directTcp", "endpoint": "10.0.0.9:6767"]],
            "preferredConnectionId": NSNull(),
        ])]))
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.hosts.count == 1)
    }

    @Test("treats a null or empty label as no label")
    func emptyLabels() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_null", "label": NSNull()]),
            profile(["serverId": "srv_empty", "label": ""]),
            profile([
                "serverId": "srv_empty_pipe",
                "label": "",
                "connections": [["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"]],
            ]),
        ]))
        #expect(snapshot.hosts.map(\.label) == [nil, nil])
        // An empty name would open a failure row with a bare dash.
        #expect(try #require(snapshot.failures.first).hasPrefix("srv_empty_pipe "))
    }

    @Test("throws on JSON that is not an array of profiles")
    func notAnArray() {
        #expect(throws: RegistryError.notAnArray) {
            try PaseoRegistry.hostEntries(fromJSON: "{\"nope\":true}")
        }
    }

    @Test("throws on malformed JSON rather than returning an empty host list")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            try PaseoRegistry.hostEntries(fromJSON: "{{{")
        }
    }
}

struct PaseoRegistryDirectoryTests {
    private func seedLevelDbDir(_ appSupport: URL, _ appDir: String) throws -> URL {
        let dir = appSupport.appendingPathComponent("\(appDir)/Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("returns the Paseo path when that directory exists")
    func found() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let expected = try seedLevelDbDir(appSupport, "Paseo")
        #expect(try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path) == expected.path)
    }

    @Test("does not probe a development build's directory, whose storage is keyed under another origin")
    func ignoresDevBuild() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        _ = try seedLevelDbDir(appSupport, "@getpaseo/desktop")
        #expect(throws: RegistryError.self) {
            try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
        }
    }

    @Test("throws naming the probed path when it does not exist")
    func namesPath() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        do {
            _ = try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
            Issue.record("expected levelDbDir to throw")
        } catch let error as RegistryError {
            #expect(error.message.contains("\(appSupport.path)/Paseo/Local Storage/leveldb"))
            #expect(error.message.contains("not found"))
        }
    }

    @Test("reports a directory it cannot reach as its own problem, not as the app being absent")
    func notADirectory() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        // A regular file where the `Paseo` directory should be: `access` fails
        // with ENOTDIR, not ENOENT. Telling the user to install Paseo would be wrong.
        try Data("not a directory".utf8).write(to: appSupport.appendingPathComponent("Paseo"))
        do {
            _ = try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
            Issue.record("expected levelDbDir to throw")
        } catch let error as RegistryError {
            #expect(!error.message.contains("not found"))
            #expect(error.message.contains("ENOTDIR"))
        }
    }

    @Test("returns nil when the directory exists but holds no registry key")
    func noRegistryKey() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("deleted", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path) == nil)
    }

    @Test("returns mapped hosts when pointed at a real fixture")
    func realFixture() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("log-only", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path) == RegistrySnapshot(
            hosts: [.directTcp(id: "srv_fixture01", label: "log-only", endpoint: "localhost:6767", useTls: false, password: nil)],
            failures: []
        ))
    }

    @Test("reads a registry stored with the UTF-16LE value encoding")
    func utf16Fixture() throws {
        // Chromium picks the encoding per value, so both tags are reachable
        // from the same database.
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("utf16", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path)?.hosts.first?.label == "utf16")
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'PaseoRegistryTests|PaseoRegistryDirectoryTests'`
Expected: `Test run with 21 tests in 2 suites passed`, the same 21 the TypeScript suite has.

- [ ] **Step 4: Mutate to prove the isolation rule bites**

In `PaseoRegistry.hostEntries`, in the `catch let error as ProfileError` branch, replace the `failures.append` and `continue` with `throw error`. Run the filter.
Expected: `names a profile that does not parse and keeps the rest` fails. That is the rule the design doc states as "one bad profile never costs another host". Revert and confirm green.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): validated host config and the Paseo registry parser

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The registry session and watcher

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/RegistrySession.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/RegistryWatcher.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Registry/FSEventsWatch.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/RegistrySessionTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/RegistryWatcherTests.swift`

**Ports:** `src/registry/registry-session.ts` and `src/registry/registry-watcher.ts` and their tests. `FSEventsWatch` replaces the `fs.watch` closure `src/main.ts` passed in.

**Deliberate difference:** the Electron build watched the directory with `fs.watch`. FSEvents is used here with `kFSEventStreamCreateFlagFileEvents`, because a directory-level watch never sees Chromium appending to an existing `.log`, and with `kFSEventStreamCreateFlagWatchRoot`, so a reinstall that replaces the directory reports as the watch dying and the watcher re-attaches.

**Interfaces:**
- Consumes `PaseoRegistry`, `AppConfig`, `hostsFingerprint`, `errorText`.
- Produces `RegistrySession(readRegistry:watch:applyConfig:onConfigError:afterRead:pollInterval:debounce:clock:)` with `start()`, `refresh()`, `noteEntryFailures(_:)`, `stop()`, `RegistrySession.noHostsMessage`; `RegistryWatcher(resolveDir:open:)` with `watch(_:)`, `ensureAttached()`, `isRegistryFileEvent(_:)`; `FSEventsWatch.open(directory:onChange:onError:)`, `FSEventsWatchError`.

- [ ] **Step 1: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/Registry/RegistrySession.swift`:

```swift
import Foundation

/// Owns the tray's view of the Paseo app's host registry: when to re-read
/// it, whether anything changed, and what the error row says. Nothing here
/// throws out of `start` or `refresh`: a menu-bar app that dies on a torn
/// read of another program's database leaves the user nothing to fix it
/// with.
@MainActor
public final class RegistrySession {
    public static let noHostsMessage = "No hosts yet. Pair a host in the Paseo app."

    private let readRegistry: () async throws -> RegistrySnapshot?
    private let watch: (@escaping () -> Void) -> () -> Void
    private let applyConfig: (AppConfig) async throws -> Void
    private let onConfigError: (String?) -> Void
    private let afterRead: (() -> Void)?
    private let pollInterval: Duration
    private let debounce: Duration
    private let clock: any Clock<Duration>

    private var appliedFingerprint: String?
    private var stopWatching: (() -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var chain: Task<Void, Never>?

    // Two independent problems, reported through one menu row: reading the
    // registry, and entries the fleet could not use. Neither may clear the other.
    private var registryError: String?
    private var fleetError: String?

    /// - Parameters:
    ///   - readRegistry: production passes `PaseoRegistry.read`.
    ///   - watch: starts watching; returns the stop function.
    ///   - afterRead: runs after every read, failed ones included. Production
    ///     re-attaches the directory watch here, which is what makes installing
    ///     Paseo mid-session take effect on the next poll.
    ///   - pollInterval: safety net for events the watcher misses. Zero disables it.
    public init(
        readRegistry: @escaping () async throws -> RegistrySnapshot?,
        watch: @escaping (@escaping () -> Void) -> () -> Void,
        applyConfig: @escaping (AppConfig) async throws -> Void,
        onConfigError: @escaping (String?) -> Void,
        afterRead: (() -> Void)? = nil,
        pollInterval: Duration = .seconds(60),
        debounce: Duration = .milliseconds(500),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.readRegistry = readRegistry
        self.watch = watch
        self.applyConfig = applyConfig
        self.onConfigError = onConfigError
        self.afterRead = afterRead
        self.pollInterval = pollInterval
        self.debounce = debounce
        self.clock = clock
    }

    /// Reads once and applies. Never throws.
    public func start() async {
        stopWatching = watch { [weak self] in self?.scheduleDebouncedRefresh() }
        if pollInterval > .zero {
            pollTask = Task { [weak self] in
                while true {
                    guard let self else { return }
                    do { try await self.clock.sleep(for: self.pollInterval) } catch { return }
                    await self.refresh()
                }
            }
        }
        await refresh()
    }

    /// Re-reads. Never throws. Reads are serialized so a watcher burst cannot
    /// interleave two applies.
    public func refresh() async {
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.readAndApply()
        }
        chain = task
        await task.value
    }

    /// The fleet's unusable entries, for the half of the error row it owns.
    public func noteEntryFailures(_ failures: [String]) {
        fleetError = failures.isEmpty ? nil : Self.describeUnusableHosts(failures)
        refreshConfigError()
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        stopWatching?()
        stopWatching = nil
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(for: self.debounce) } catch { return }
            self.debounceTask = nil
            await self.refresh()
        }
    }

    private static func describeUnusableHosts(_ failures: [String]) -> String {
        "These hosts could not be used:\n\n\(failures.joined(separator: "\n"))"
    }

    private func refreshConfigError() {
        let problems = [registryError, fleetError].compactMap { $0 }
        onConfigError(problems.isEmpty ? nil : problems.joined(separator: "\n\n"))
    }

    /// One read, start to finish, that cannot throw.
    private func readAndApply() async {
        await readOnce()
        afterRead?()
    }

    private func readOnce() async {
        let snapshot: RegistrySnapshot?
        do {
            snapshot = try await readRegistry()
        } catch {
            // Keep the last known-good host set live and say what went wrong.
            registryError = errorText(error)
            refreshConfigError()
            return
        }

        let hosts = snapshot?.hosts ?? []
        let failures = snapshot?.failures ?? []

        var problems: [String] = []
        // Absent key and empty array are the same dead end for the user.
        if hosts.isEmpty && failures.isEmpty { problems.append(Self.noHostsMessage) }
        if let warning = snapshot?.warning { problems.append(warning) }
        if !failures.isEmpty { problems.append(Self.describeUnusableHosts(failures)) }

        // The host set is hand-built from another program's storage, so it is
        // validated before the fleet sees it; this is the only path that builds a config.
        let config: AppConfig
        do {
            config = try AppConfig.validate(hosts: hosts)
        } catch {
            problems.append("The Paseo app's host list could not be used:\n\n\(errorText(error))")
            registryError = problems.joined(separator: "\n\n")
            refreshConfigError()
            return
        }

        registryError = problems.isEmpty ? nil : problems.joined(separator: "\n\n")
        refreshConfigError()

        // Rebuilding tears down live connections, so only when the host set differs.
        let fingerprint = hostsFingerprint(config.hosts)
        if fingerprint == appliedFingerprint { return }
        do {
            try await applyConfig(config)
            // Recorded only once the fleet has actually taken it.
            appliedFingerprint = fingerprint
        } catch {
            // The fleet may be half torn down, so nothing counts as applied any more.
            appliedFingerprint = nil
            problems.append("The hosts could not be applied:\n\n\(errorText(error))")
            registryError = problems.joined(separator: "\n\n")
            refreshConfigError()
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/RegistryWatcher.swift`:

```swift
import Foundation

/// Keeps a filesystem watch on the Paseo app's leveldb directory attached,
/// across the directory not existing yet and across the watch failing later.
/// `ensureAttached` is the seam: the session calls it after every read, so
/// the first read that works is also what attaches the watch. Nothing here
/// throws. The watch implementation is injected, which keeps this free of
/// the filesystem and lets the reattachment logic be tested directly.
@MainActor
public final class RegistryWatcher {
    /// Starts one watch and returns its detach function. A failure after the
    /// watch is up is reported through `onError`; a throw here is tolerated,
    /// the watcher stays unattached and the next read tries again.
    public typealias Open = (_ dir: String, _ onChange: @escaping () -> Void, _ onError: @escaping () -> Void) throws -> () -> Void

    private let resolveDir: () async throws -> String
    private let open: Open
    private var notify: (() -> Void)?
    private var detach: (() -> Void)?
    private var resolving = false

    public init(resolveDir: @escaping () async throws -> String, open: @escaping Open) {
        self.resolveDir = resolveDir
        self.open = open
    }

    /// Whether a directory event names a file the reader opens. LevelDB's
    /// bookkeeping files (`LOG`, `MANIFEST-*`, `CURRENT`, `LOCK`) cannot
    /// change the registry's value, so they are not worth a rescan.
    public nonisolated static func isRegistryFileEvent(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".ldb") || name.hasSuffix(".sst") || name.hasSuffix(".log")
    }

    /// Matches `RegistrySession`'s `watch`. Returns the detach function.
    public func watch(_ onChange: @escaping () -> Void) -> () -> Void {
        notify = onChange
        ensureAttached()
        return { [weak self] in
            guard let self else { return }
            self.notify = nil
            let current = self.detach
            self.detach = nil
            current?()
        }
    }

    /// Attaches if nothing is attached. Safe to call on every read; a burst of
    /// reads while the first resolution is pending opens one watch, not one per read.
    public func ensureAttached() {
        guard notify != nil, detach == nil, !resolving else { return }
        resolving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let dir = try await self.resolveDir()
                self.resolving = false
                guard self.notify != nil, self.detach == nil else { return }
                self.detach = try self.open(
                    dir,
                    { [weak self] in self?.notify?() },
                    // The watch died. Forget it so the next ensureAttached opens a fresh one.
                    { [weak self] in self?.detach = nil }
                )
            } catch {
                // Paseo is not installed, or the directory vanished between
                // resolution and open. Nothing is attached; the next read tries again.
                self.resolving = false
            }
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Registry/FSEventsWatch.swift`:

```swift
import CoreServices
import Foundation

public enum FSEventsWatchError: MessageError {
    case couldNotStart(String)

    public var message: String {
        switch self {
        case .couldNotStart(let dir): "Could not start watching \(dir)"
        }
    }
}

/// The production watch behind `RegistryWatcher`: FSEvents on the leveldb
/// directory with per-file events, because Chromium appends to an existing
/// `.log` and a plain directory watch never sees that. A root change (the
/// directory deleted or replaced, which a reinstall does) is reported as the
/// watch dying, so the watcher re-attaches on its next read.
public enum FSEventsWatch {
    @MainActor
    public static func open(directory: String, onChange: @escaping () -> Void, onError: @escaping () -> Void) throws -> () -> Void {
        let stream = try Stream(directory: directory, onChange: onChange, onError: onError)
        return { stream.stop() }
    }

    @MainActor
    private final class Stream {
        private var ref: FSEventStreamRef?
        private let onChange: () -> Void
        private let onError: () -> Void
        private var stopped = false

        init(directory: String, onChange: @escaping () -> Void, onError: @escaping () -> Void) throws {
            self.onChange = onChange
            self.onError = onError
            var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Stream.callback,
                &context,
                [directory] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                flags
            ) else {
                throw FSEventsWatchError.couldNotStart(directory)
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw FSEventsWatchError.couldNotStart(directory)
            }
            ref = stream
        }

        func stop() {
            guard let stream = ref, !stopped else { return }
            stopped = true
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            ref = nil
        }

        private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard !stopped else { return }
            var rootChanged = false
            var relevant = false
            for (path, flag) in zip(paths, flags) {
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
                if RegistryWatcher.isRegistryFileEvent(path) { relevant = true }
            }
            if rootChanged {
                stop()
                onError()
                return
            }
            if relevant { onChange() }
        }

        private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self).compactMap { $0 as? String }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            // The stream was scheduled on the main queue, so this runs there.
            MainActor.assumeIsolated { stream.handle(paths: paths, flags: flags) }
        }
    }
}
```

- [ ] **Step 2: Write the tests**

Both harnesses build their subject *after* their stored properties, so the callbacks can capture `self`. A capture list evaluated before the object exists captures nothing, and every callback then goes nowhere — which is a silent pass-shaped failure, not a compile error.

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/RegistrySessionTests.swift`:

```swift
import Clocks
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct RegistrySessionTests {
    private static func host(_ id: String) -> HostEntry {
        .directTcp(id: id, label: id, endpoint: "10.0.0.1:6767", useTls: false, password: nil)
    }

    /// Reads are supplied one per call, sticking on the last entry.
    @MainActor
    final class Harness {
        enum Read {
            case snapshot(RegistrySnapshot?)
            case failure(String)
        }

        let clock = TestClock()
        private(set) var applied: [AppConfig] = []
        private(set) var errors: [String?] = []
        private(set) var afterReads = 0
        private(set) var reads = 0
        private(set) var unwatched = false
        var fire: () -> Void = {}
        /// Set to make the next apply throw with this message.
        var applyFailure: String?
        /// Set to make an apply throw only when the config holds this host id.
        var applyFailureFor: String?
        var script: [Read]
        /// Set to answer every later read with this snapshot, ignoring the script.
        var current: RegistrySnapshot?
        /// Built after the stored properties so the callbacks can capture self.
        private(set) var session: RegistrySession!

        init(_ script: [Read], pollInterval: Duration = .zero) {
            self.script = script
            session = RegistrySession(
                readRegistry: { [weak self] in
                    guard let self else { return nil }
                    return try self.nextRead()
                },
                watch: { [weak self] onChange in
                    self?.fire = onChange
                    return { [weak self] in self?.unwatched = true }
                },
                applyConfig: { [weak self] config in
                    guard let self else { return }
                    try self.apply(config)
                },
                onConfigError: { [weak self] message in self?.errors.append(message) },
                afterRead: { [weak self] in self?.afterReads += 1 },
                pollInterval: pollInterval,
                clock: clock
            )
        }

        func nextRead() throws -> RegistrySnapshot? {
            reads += 1
            if let current { return current }
            let index = min(reads - 1, script.count - 1)
            switch script[index] {
            case .snapshot(let snapshot): return snapshot
            case .failure(let message): throw LevelDBReadError(message: message, cause: nil)
            }
        }

        func apply(_ config: AppConfig) throws {
            if let failure = applyFailure {
                applyFailure = nil
                throw LevelDBReadError(message: failure, cause: nil)
            }
            if let id = applyFailureFor, config.hosts.contains(where: { $0.id == id }) {
                throw LevelDBReadError(message: "fleet rebuild blew up", cause: nil)
            }
            applied.append(config)
        }

        var lastError: String? { errors.last ?? nil }
    }

    @Test("applies the hosts it read and clears the error row")
    func appliesHosts() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        await h.session.start()
        #expect(h.applied.count == 1)
        #expect(h.applied.first?.hosts.map(\.id) == ["a"])
        #expect(h.lastError == nil)
    }

    @Test("does not rebuild the fleet when the host set is unchanged")
    func unchangedSet() async {
        let snapshot = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        let h = Harness([.snapshot(snapshot), .snapshot(snapshot)])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 1)
    }

    @Test("rebuilds when the host set actually changes")
    func changedSet() async {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .snapshot(RegistrySnapshot(hosts: [Self.host("a"), Self.host("b")], failures: [])),
        ])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.map(\.id) == ["a", "b"])
    }

    @Test("keeps the last known-good hosts when a later read fails")
    func readFailure() async throws {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .failure("torn read"),
        ])
        await h.session.start()
        await h.session.refresh()
        // Nothing re-applied: the good host set stays live.
        #expect(h.applied.count == 1)
        #expect(try #require(h.lastError).contains("torn read"))
    }

    @Test("applies an empty host set when the registry key is absent")
    func absentKey() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])), .snapshot(nil)])
        await h.session.start()
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.isEmpty == true)
        #expect(try #require(h.lastError).contains("No hosts yet"))
    }

    @Test("applies the hosts it got and still reports a partly unreadable database")
    func warningWithHosts() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(
            hosts: [Self.host("a")],
            failures: [],
            warning: "Could not read 1 of 2 LevelDB file(s) in /db; the host list may be out of date"
        ))])
        await h.session.start()
        // Dropping the hosts over one torn file empties the tray; dropping the
        // warning presents a possibly-superseded host list as healthy.
        #expect(h.applied.first?.hosts.map(\.id) == ["a"])
        #expect(try #require(h.lastError).contains("out of date"))
    }

    @Test("refuses a host set the config validation rejects, and keeps the last good one")
    func duplicateIds() async throws {
        let h = Harness([
            .snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: [])),
            .snapshot(RegistrySnapshot(hosts: [Self.host("a"), Self.host("a")], failures: [])),
        ])
        await h.session.start()
        await h.session.refresh()
        // Two entries under one id would leave an orphaned connection whose
        // socket and subscription never stop.
        #expect(h.applied.count == 1)
        #expect(try #require(h.lastError).contains("Duplicate host id"))
    }

    @Test("refuses a relay entry whose offer fields are empty")
    func emptyOfferFields() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(
            hosts: [.relay(id: "r1", label: nil, offer: ConnectionOffer(serverId: "srv", daemonPublicKeyB64: "", relay: .init(endpoint: "", useTls: true)))],
            failures: []
        ))])
        await h.session.start()
        // The offer's own constraints are the only thing between an empty
        // credential from the registry and the connection code.
        #expect(h.applied.isEmpty)
        #expect(try #require(h.lastError).contains("could not be used"))
    }

    @Test("points at the Paseo app when the registry holds an empty host array")
    func emptyRegistry() async throws {
        // Distinct from an absent key: Paseo is installed and has stored a
        // registry, it is just empty. Without a row the user gets zero hosts
        // and no route forward at all.
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [], failures: []))])
        await h.session.start()
        #expect(h.applied.count == 1)
        #expect(h.applied.first?.hosts.isEmpty == true)
        #expect(try #require(h.lastError).contains("No hosts yet"))
    }

    @Test("re-applies the host set after applyConfig fails, rather than marking it applied")
    func applyFailure() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        h.applyFailure = "fleet rebuild blew up"
        await h.session.start()
        #expect(h.applied.isEmpty)
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))

        // The fingerprint must not have been claimed: the next read sees the
        // same host set, and if it counted as applied the fleet would never
        // receive it while the successful read cleared the error row.
        await h.session.refresh()
        #expect(h.applied.count == 1)
        #expect(h.lastError == nil)
    }

    @Test("re-applies the previous host set when the registry reverts after a failed apply")
    func revertAfterFailedApply() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        h.current = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        await h.session.start()
        #expect(h.applied.count == 1)

        // The fleet tears down before it rebuilds, so a rebuild that throws
        // leaves it empty; whatever was live before is gone too.
        h.current = RegistrySnapshot(hosts: [Self.host("b")], failures: [])
        h.applyFailureFor = "b"
        await h.session.refresh()
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))

        // The user reverts in Paseo. Treating that as "unchanged" left the
        // fleet empty with a clear error row: no hosts, no error, no way back.
        h.current = RegistrySnapshot(hosts: [Self.host("a")], failures: [])
        await h.session.refresh()
        #expect(h.applied.count == 2)
        #expect(h.applied.last?.hosts.map(\.id) == ["a"])
        #expect(h.lastError == nil)
    }

    @Test("keeps the read's own problems in the row when the apply fails")
    func problemsSurviveFailedApply() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: ["Pipe only — no connection the menu bar can use"]))])
        h.applyFailure = "fleet rebuild blew up"
        await h.session.start()
        // Both are true at once and both are the user's to act on.
        #expect(try #require(h.lastError).contains("Pipe only"))
        #expect(try #require(h.lastError).contains("fleet rebuild blew up"))
    }

    @Test("runs afterRead after every read, failed ones included")
    func afterReadHook() async {
        let h = Harness([.failure("Paseo desktop app not found")])
        await h.session.start()
        // A failed read is exactly the case that matters: the directory was
        // absent at launch, and this is what re-checks for it on every poll.
        #expect(h.afterReads == 1)
        await h.session.refresh()
        #expect(h.afterReads == 2)
    }

    @Test("stop cancels the pending read, the poll, and the watcher")
    func stopCancels() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))], pollInterval: .milliseconds(100))
        await h.session.start()
        #expect(h.reads == 1)

        h.fire() // schedules a debounced read that stop() has to cancel
        h.session.stop()
        await h.clock.advance(by: .seconds(2))
        await settle()

        #expect(h.unwatched)
        #expect(h.reads == 1)
    }

    @Test("debounces a burst of watcher events into one read")
    func debounces() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))])
        await h.session.start()
        #expect(h.reads == 1)
        h.fire()
        h.fire()
        h.fire()
        await settle()
        await h.clock.advance(by: .milliseconds(600))
        await settle()
        #expect(h.reads == 2)
        h.session.stop()
    }

    @Test("polls on its own interval as a safety net for events the watcher missed")
    func polls() async {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: []))], pollInterval: .seconds(60))
        await h.session.start()
        #expect(h.reads == 1)
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.reads == 2)
        h.session.stop()
    }

    @Test("surfaces dropped hosts in the error row")
    func droppedHosts() async throws {
        let h = Harness([.snapshot(RegistrySnapshot(hosts: [Self.host("a")], failures: ["Pipe only — no connection the menu bar can use"]))])
        await h.session.start()
        #expect(try #require(h.lastError).contains("Pipe only"))
    }

    @Test("shows a registry problem and a fleet problem at the same time")
    func bothProblems() async throws {
        let h = Harness([.snapshot(nil)])
        await h.session.start()
        h.session.noteEntryFailures(["h1 — unreachable"])
        #expect(try #require(h.lastError).contains("No hosts yet"))
        #expect(try #require(h.lastError).contains("h1 — unreachable"))
    }

    @Test("clearing the fleet's problems does not clear the registry's")
    func independentProblems() async throws {
        let h = Harness([.snapshot(nil)])
        await h.session.start()
        h.session.noteEntryFailures(["h1 — unreachable"])
        h.session.noteEntryFailures([])
        #expect(try #require(h.lastError).contains("No hosts yet"))
        #expect(!(try #require(h.lastError).contains("unreachable")))
    }

    @Test("never throws when the first read fails")
    func firstReadFails() async throws {
        let h = Harness([.failure("nope")])
        await h.session.start()
        #expect(try #require(h.lastError).contains("nope"))
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/RegistryWatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct RegistryWatcherTests {
    @MainActor
    final class OpenCall {
        let dir: String
        let fire: () -> Void
        let fail: () -> Void
        var closed = false

        init(dir: String, fire: @escaping () -> Void, fail: @escaping () -> Void) {
            self.dir = dir
            self.fire = fire
            self.fail = fail
        }
    }

    @MainActor
    final class Harness {
        private(set) var opens: [OpenCall] = []
        private(set) var probes = 0
        var changes = 0
        /// Built after the stored properties so the callbacks can capture self.
        private(set) var watcher: RegistryWatcher!

        init(resolveDir: @escaping () async throws -> String, openThrows: ((Int) -> Bool)? = nil) {
            watcher = RegistryWatcher(
                resolveDir: { [weak self] in
                    self?.probes += 1
                    return try await resolveDir()
                },
                open: { [weak self] dir, onChange, onError in
                    guard let self else { return {} }
                    let attempt = self.opens.count + 1
                    if openThrows?(attempt) == true {
                        // `fs.watch`'s equivalent: the directory vanished
                        // between resolution and the call.
                        self.opens.append(OpenCall(dir: dir, fire: {}, fail: {}))
                        throw FSEventsWatchError.couldNotStart(dir)
                    }
                    let call = OpenCall(dir: dir, fire: onChange, fail: onError)
                    self.opens.append(call)
                    return { call.closed = true }
                }
            )
        }
    }

    @Test("attaches to the resolved directory and forwards changes")
    func attaches() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch { h.changes += 1 }
        await settle()

        #expect(h.opens.count == 1)
        #expect(h.opens.first?.dir == "/db")
        h.opens.first?.fire()
        #expect(h.changes == 1)
    }

    @Test("attaches on a later read when Paseo was not installed at launch")
    func attachesLater() async {
        var installed = false
        let h = Harness(resolveDir: {
            if !installed { throw RegistryError.appNotFound(dir: "/db") }
            return "/db"
        })

        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.isEmpty)

        // Installing Paseo mid-session used to leave the app on the 60-second
        // poll for the life of the process.
        installed = true
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("never throws when the directory cannot be resolved")
    func resolveFailure() async {
        let h = Harness(resolveDir: { throw RegistryError.appNotFound(dir: "/db") })
        // An unhandled error here would be fatal in the app.
        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.isEmpty)
    }

    @Test("does not open a second watch while one is already attached")
    func singleWatch() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch {}
        await settle()
        h.watcher.ensureAttached()
        h.watcher.ensureAttached()
        await settle()

        #expect(h.opens.count == 1)
    }

    @Test("does not probe the directory again while a probe is in flight")
    func singleProbe() async {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/db"
        })

        _ = h.watcher.watch {}
        await settle()
        h.watcher.ensureAttached()
        h.watcher.ensureAttached()
        await settle()

        // `ensureAttached` runs after every read, so without this guard a slow
        // probe would stack one more on each poll.
        #expect(h.probes == 1)
        gate.open()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("re-attaches after the watch reports an error")
    func reattaches() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch {}
        await settle()

        // macOS drops watches when the watched directory is replaced, which a
        // compaction does. Without a fresh attach the tray is on the poll alone.
        h.opens.first?.fail()
        h.watcher.ensureAttached()
        await settle()

        #expect(h.opens.count == 2)
    }

    @Test("stops watching and stops forwarding once detached")
    func detaches() async {
        let h = Harness(resolveDir: { "/db" })
        let stop = h.watcher.watch { h.changes += 1 }
        await settle()

        stop()
        #expect(h.opens.first?.closed == true)
        h.opens.first?.fire()
        #expect(h.changes == 0)

        // And a read arriving after shutdown must not resurrect it.
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("stays detached, and tries again later, when open itself throws")
    func openThrows() async {
        let h = Harness(resolveDir: { "/db" }, openThrows: { $0 == 1 })
        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.count == 1)

        // A throw must not count as attached, or the tray sits on the poll for
        // the life of the process with a watch it never had.
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 2)
    }

    @Test("does not attach a directory that resolves after the watcher was detached")
    func resolvesAfterDetach() async {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/db"
        })

        let stop = h.watcher.watch {}
        await settle()
        stop()
        gate.open()
        await settle()

        #expect(h.opens.isEmpty)
    }

    @Test("passes the files the reader opens and drops LevelDB's bookkeeping")
    func fileFilter() {
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000005.ldb"))
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000004.sst"))
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000036.log"))
        for name in ["LOG", "LOG.old", "LOCK", "CURRENT", "MANIFEST-000001", "000037.dbtmp"] {
            #expect(!RegistryWatcher.isRegistryFileEvent("/db/\(name)"), "\(name)")
        }
    }
}

/// A one-shot gate a test opens to release a pending async call.
final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false

    func open() {
        guard !opened else { return }
        opened = true
        semaphore.signal()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'RegistrySessionTests|RegistryWatcherTests'`
Expected: `Test run with 30 tests in 2 suites passed`.

- [ ] **Step 4: Mutate to prove the fingerprint rule bites**

In `RegistrySession.readOnce`, move `appliedFingerprint = fingerprint` from after the successful `applyConfig` to before it. Run the filter.
Expected: `re-applies the host set after applyConfig fails, rather than marking it applied` fails. Revert.

Then, in the `catch` of the same block, delete `appliedFingerprint = nil`. Expected: `re-applies the previous host set when the registry reverts after a failed apply` fails. Revert and confirm green. Both are failures the TypeScript comments record as having actually happened.

- [ ] **Step 5: Run the whole suite**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 192 tests in 20 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): registry session, watcher, and the FSEvents watch

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The host store and the fleet

**Files:**
- Modify: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/DaemonMessages.swift`
- Modify: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostSink.swift`
- Modify: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostConnection.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Store/HostStore.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostFleet.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/TrayFixtures.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Store/HostStoreTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Store/HostFleetTests.swift`

**Ports:** `src/daemon/host-store.ts` and `src/daemon/host-fleet.ts` and their tests.

**Two deliberate differences:**

1. **The fleet is synchronous.** `HostConnection.close()` returns immediately rather than awaiting a socket, so `apply` and `retry` have no await point for two calls to interleave through. The TypeScript fleet's `serialize` helper and the two tests that pin its ordering have no counterpart here; the generation-ordering test that replaces them asserts the same observable property, that every close of one generation precedes every create of the next.
2. **Teardown follows config order.** The TypeScript iterated a `Map`, which preserves insertion order. A Swift `Dictionary` does not, so `closeAll` walks `appliedHosts` instead. Without this the close order varies run to run, which makes both the logs and the tests non-reproducible — it failed the generation-ordering test on the first full-suite run.

**Interfaces:**
- Consumes `HostSink`, `HostConnection`, `AppConfig`, `hostsFingerprint`, `errorText`.
- Produces `AgentPermissionRequest`, `AgentSnapshot.statusPriority`, memberwise initializers on `AgentSnapshot` and `WorkspaceDescriptor`, `HostConnecting`, `HostSnapshot`, `HostStore` (the `HostSink` plus `setConfigError`, `getConfigError`, `snapshot`, `subscribe`), `HostFleet(store:onEntryFailures:makeConnection:)` with `apply(_:)`, `retry(_:)`, `webBaseUrl(for:)`, `firstWebBaseUrl()`, `closeAll()`, `FleetError`, `HostEntry.webBaseUrl`.
- Test support produces `Fixture` with `agent`, `workspace`, `host`, `directEntry`, `relayEntry`, `config`.

- [ ] **Step 1: Extend the wire models**

The view model ranks a workspace's agents by the daemon's own urgency order, and the first term of that order is the count of pending permissions — a field the foundation never decoded. In `DaemonMessages.swift`, add above `AgentSnapshot`:

```swift
/// One pending permission request. Only the count matters here: it is the
/// first term of the daemon's own urgency ranking.
public struct AgentPermissionRequest: Codable, Equatable, Sendable {
    public let id: String?
}
```

Add `public let pendingPermissions: [AgentPermissionRequest]?` to `AgentSnapshot`, give it a memberwise `init` defaulting every optional to nil, and add:

```swift
    /// The daemon's own urgency ranking, lower being more urgent, copied from
    /// `getAgentStatusPriority` in `@getpaseo/protocol`'s `agent-state-bucket`.
    /// Ranks pending permission 0, error 1, running 2, initializing 3, and
    /// everything else 4.
    public var statusPriority: Int {
        if (pendingPermissions?.count ?? 0) > 0 || attentionReason == "permission" { return 0 }
        if status == "error" || attentionReason == "error" { return 1 }
        if status == "running" { return 2 }
        if status == "initializing" { return 3 }
        return 4
    }
```

Give `WorkspaceDescriptor` a memberwise `init` too, defaulting `projectId` to `"p1"`, `projectDisplayName` to `"paseo"`, and the rest to nil, so tests can build one without a JSON round trip.

- [ ] **Step 2: Add the connection protocol**

Append to `HostSink.swift`:

```swift
/// What the fleet holds: one host's connection, closable. `HostConnection` is
/// the only production conformance; the fleet depends on this so its
/// bookkeeping can be tested without a socket.
@MainActor
public protocol HostConnecting: AnyObject {
    func close()
}
```

and in `HostConnection.swift` change the declaration to `public final class HostConnection: HostConnecting {`.

- [ ] **Step 3: Write the store and the fleet**

`PaseoIconPackage/Sources/PaseoIconCore/Store/HostStore.swift`:

```swift
import Foundation

/// One host's replicated state. Two lists, because they answer two different
/// questions: `workspaces` is what the menu shows, the same unit and the same
/// daemon-computed bucket the Paseo sidebar renders, and `agents` exists only
/// to resolve a click, since there is no workspace deep link.
public struct HostSnapshot: Equatable, Sendable {
    public let hostId: String
    /// The user's explicit name from the registry. Nil when the entry has
    /// none. The raw value, not the resolved display name: see `resolveHostName`.
    public let label: String?
    /// The daemon's own hostname, from the live `server_info` message.
    public let hostname: String?
    /// The entry's own connection address, the last-resort name.
    public let endpointHint: String
    public let status: HostStatus
    public let serverId: String?
    public let workspaces: [WorkspaceDescriptor]
    public let agents: [AgentSnapshot]
    /// The host has more workspaces than the seed page could carry.
    public let workspacesTruncated: Bool
    /// The host has more agents than the seed page could carry.
    public let agentsTruncated: Bool
}

/// Replicated workspace and agent state, keyed by host. The `HostSink` a
/// `HostConnection` reports into, plus the configuration error the menu shows.
@MainActor
public final class HostStore: HostSink {
    private struct Entry {
        var label: String?
        var hostname: String?
        var endpointHint: String
        var status: HostStatus
        var serverId: String?
        var workspaces: [String: WorkspaceDescriptor] = [:]
        var agents: [String: AgentSnapshot] = [:]
        var workspacesTruncated = false
        var agentsTruncated = false
        /// Insertion order, so the menu's host rows follow config order rather
        /// than a dictionary's arbitrary one.
        var order: Int
    }

    private var hosts: [String: Entry] = [:]
    private var nextOrder = 0
    private var listeners: [UUID: () -> Void] = [:]
    private var configError: String?

    public init() {}

    /// A configuration problem the user has to fix. It rides in the store so
    /// the menu can show it: a modal error box steals focus from the app the
    /// user is fixing it in, and on its own leaves the tray showing an
    /// unexplained "No workspaces".
    public func setConfigError(_ message: String?) {
        guard configError != message else { return }
        configError = message
        emit()
    }

    public func getConfigError() -> String? { configError }

    public func setHost(_ hostId: String, label: String?, endpointHint: String) {
        if var existing = hosts[hostId] {
            existing.label = label
            existing.endpointHint = endpointHint
            hosts[hostId] = existing
        } else {
            hosts[hostId] = Entry(label: label, hostname: nil, endpointHint: endpointHint, status: .connecting, serverId: nil, order: nextOrder)
            nextOrder += 1
        }
        emit()
    }

    public func removeHost(_ hostId: String) {
        guard hosts.removeValue(forKey: hostId) != nil else { return }
        emit()
    }

    public func setStatus(_ hostId: String, _ status: HostStatus) {
        guard var host = hosts[hostId], host.status != status else { return }
        host.status = status
        hosts[hostId] = host
        emit()
    }

    public func setServerId(_ hostId: String, _ serverId: String) {
        guard var host = hosts[hostId], host.serverId != serverId else { return }
        host.serverId = serverId
        hosts[hostId] = host
        emit()
    }

    /// The daemon's own hostname, carried the same way `serverId` is.
    public func setHostname(_ hostId: String, _ hostname: String?) {
        guard var host = hosts[hostId], host.hostname != hostname else { return }
        host.hostname = hostname
        hosts[hostId] = host
        emit()
    }

    /// Replaces the host's agents wholesale: a subscription gap must not
    /// strand a dead row.
    public func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        guard var host = hosts[hostId] else { return }
        host.agents = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        host.agentsTruncated = truncated
        hosts[hostId] = host
        emit()
    }

    /// Replaces the host's workspaces wholesale. Same rule as `seedAgents`.
    public func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        guard var host = hosts[hostId] else { return }
        host.workspaces = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        host.workspacesTruncated = truncated
        hosts[hostId] = host
        emit()
    }

    public func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) {
        guard var host = hosts[hostId] else { return }
        switch update {
        case .upsert(let agent):
            host.agents[agent.id] = agent
        case .remove(let agentId):
            guard host.agents.removeValue(forKey: agentId) != nil else { return }
        }
        hosts[hostId] = host
        emit()
    }

    public func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) {
        guard var host = hosts[hostId] else { return }
        switch update {
        case .upsert(let workspace):
            host.workspaces[workspace.id] = workspace
        case .remove(let id):
            guard host.workspaces.removeValue(forKey: id) != nil else { return }
        }
        hosts[hostId] = host
        emit()
    }

    /// Hosts in the order they were registered, each with its lists in a
    /// stable order so the menu does not reshuffle between renders.
    public func snapshot() -> [HostSnapshot] {
        hosts.sorted { $0.value.order < $1.value.order }.map { hostId, host in
            HostSnapshot(
                hostId: hostId,
                label: host.label,
                hostname: host.hostname,
                endpointHint: host.endpointHint,
                status: host.status,
                serverId: host.serverId,
                workspaces: host.workspaces.values.sorted { $0.id < $1.id },
                agents: host.agents.values.sorted { $0.id < $1.id },
                workspacesTruncated: host.workspacesTruncated,
                agentsTruncated: host.agentsTruncated
            )
        }
    }

    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    private func emit() {
        for listener in listeners.values { listener() }
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Daemon/HostFleet.swift`:

```swift
import Foundation

/// Owns the set of live host connections and the config generation they were
/// built from. Everything here is the connection bookkeeping that can actually
/// go wrong, so it holds no AppKit and takes its collaborators by injection.
///
/// Unlike the Electron original this is synchronous: `HostConnection.close()`
/// returns immediately rather than awaiting a socket, so there is no await
/// point for two applies to interleave through and no serialization to do.
@MainActor
public final class HostFleet {
    public typealias MakeConnection = (HostEntry, HostStore) throws -> any HostConnecting

    private let store: HostStore
    private let onEntryFailures: ([String]) -> Void
    private let makeConnection: MakeConnection

    private var connections: [String: any HostConnecting] = [:]
    /// The entries behind the live connections, in config order. A menu row
    /// carries only a hostId, and both the web fallback and the per-host retry
    /// need the entry itself.
    private var appliedHosts: [(id: String, entry: HostEntry)] = []
    /// The unusable entries behind the caller's error row, keyed by entry id
    /// so a retry can clear its own without disturbing the other hosts'.
    private var entryFailures: [(id: String, message: String)] = []
    private var appliedFingerprint = ""

    public init(
        store: HostStore,
        onEntryFailures: @escaping ([String]) -> Void,
        makeConnection: MakeConnection? = nil
    ) {
        self.store = store
        self.onEntryFailures = onEntryFailures
        self.makeConnection = makeConnection ?? { entry, store in
            try HostConnection(entry: entry, sink: store, clock: ContinuousClock())
        }
    }

    /// Rebuilds the fleet to match `config`. No-ops when the host list is
    /// unchanged: Chromium rewrites the registry's database for keys the tray
    /// does not care about, and churning sockets over that is pure cost.
    public func apply(_ config: AppConfig) {
        let fingerprint = hostsFingerprint(config.hosts)
        if fingerprint == appliedFingerprint { return }
        // Recorded only once the fleet is actually built. Claiming it up front
        // meant a rebuild that died partway still looked applied.
        appliedFingerprint = ""

        closeAll()
        appliedHosts.removeAll()
        entryFailures.removeAll()

        for entry in config.hosts {
            appliedHosts.append((entry.id, entry))
            connect(entry)
        }

        appliedFingerprint = fingerprint
        reportEntryFailures()
    }

    /// Rebuilds one host. Auth rejection disposes its session for good, so
    /// without this a password fixed on the daemon side has no recovery path
    /// short of relaunching: the registry bytes never changed, so a reload
    /// cannot help.
    public func retry(_ hostId: String) {
        guard let entry = appliedHosts.first(where: { $0.id == hostId })?.entry else { return }
        // `close()` removes the host from the store, so the old connection goes
        // first; building the replacement first would leave a live connection
        // the store can no longer see.
        connections.removeValue(forKey: hostId)?.close()
        connect(entry)
        reportEntryFailures()
    }

    /// The base URL of the host's own web UI, when it has one.
    public func webBaseUrl(for hostId: String) -> String? {
        appliedHosts.first(where: { $0.id == hostId })?.entry.webBaseUrl
    }

    /// The web UI of the first host that is actually connected, in config
    /// order: the fallback used to open Paseo when the desktop app is absent.
    /// Any other status still yields a URL from the entry alone, which would
    /// suppress the `paseo://` fallback in favour of a browser tab that cannot
    /// load.
    public func firstWebBaseUrl() -> String? {
        let statuses = Dictionary(store.snapshot().map { ($0.hostId, $0.status) }, uniquingKeysWith: { first, _ in first })
        for host in appliedHosts where statuses[host.id] == .connected {
            if let url = host.entry.webBaseUrl { return url }
        }
        return nil
    }

    /// Closes in config order rather than the connection map's. A dictionary
    /// has no order, so teardown would otherwise vary run to run, which makes
    /// both the logs and the tests non-reproducible.
    public func closeAll() {
        for host in appliedHosts {
            connections.removeValue(forKey: host.id)?.close()
        }
        // Anything left is a connection whose entry is already gone; close it
        // rather than leak the socket.
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    /// Creates one host's connection, recording a failure description under
    /// `entry.id` when it cannot. One unusable entry must not take down every
    /// host after it: it shows as a host that exists and cannot be used, named
    /// in the error row.
    private func connect(_ entry: HostEntry) {
        do {
            // The invariant is checked rather than repaired: `AppConfig.validate`
            // rejects duplicate ids and `apply` clears the map before rebuilding,
            // so a call site that breaks it gets a named configuration error
            // instead of a live connection nothing can close.
            if connections[entry.id] != nil {
                throw FleetError.duplicateId(entry.id)
            }
            connections[entry.id] = try makeConnection(entry, store)
            entryFailures.removeAll { $0.id == entry.id }
        } catch {
            let hint = entry.endpointHint
            store.setHost(entry.id, label: entry.label, endpointHint: hint)
            store.setStatus(entry.id, .invalid)
            // Named the way `resolveHostName`'s last resort is: an unlabeled
            // entry never connected, so its own endpoint is the best identifier.
            let message = "\(entry.label ?? hint): \(errorText(error))"
            if let index = entryFailures.firstIndex(where: { $0.id == entry.id }) {
                entryFailures[index] = (entry.id, message)
            } else {
                entryFailures.append((entry.id, message))
            }
        }
    }

    private func reportEntryFailures() {
        onEntryFailures(entryFailures.map(\.message))
    }
}

public enum FleetError: MessageError, Equatable {
    case duplicateId(String)

    public var message: String {
        switch self {
        case .duplicateId(let id): "a connection for host id \"\(id)\" already exists"
        }
    }
}

extension HostEntry {
    /// The daemon serves its web UI on the same endpoint it serves the socket
    /// on, so a direct host doubles as the fallback target. A relay host has
    /// no such URL: the relay is a socket tunnel, not an HTTP origin.
    public var webBaseUrl: String? {
        guard case .directTcp(_, _, let endpoint, let useTls, _) = self else { return nil }
        return "\(useTls ? "https" : "http")://\(endpoint)"
    }
}
```

- [ ] **Step 4: Confirm the unvalidated-config hatch is already there**

The fleet's duplicate-id guard is defensive: `AppConfig.validate` already rejects duplicates, so the guard only fires for a call site that skipped validation, and that is what `HostFleetTests.duplicateId` has to construct. Task 5 already wrote the hatch, so this is a check rather than an edit.

Run: `grep -n 'unvalidated' PaseoIconPackage/Sources/PaseoIconCore/Config/AppConfig.swift`
Expected: the `static func unvalidated(hosts:)` declaration and its comment. If it is missing, Task 5 was transcribed wrong; fix it there rather than adding a second copy here.

- [ ] **Step 5: Write the fixtures and tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Support/TrayFixtures.swift`:

```swift
import Foundation
@testable import PaseoIconCore

/// Builders for the shapes the store and view model work in.
enum Fixture {
    static func agent(
        _ id: String,
        workspaceId: String? = "w1",
        status: String = "idle",
        updatedAt: String = "2026-08-16T00:00:00.000Z",
        requiresAttention: Bool? = nil,
        attentionReason: String? = nil,
        archivedAt: String? = nil,
        pendingPermissions: Int = 0
    ) -> AgentSnapshot {
        AgentSnapshot(
            id: id,
            workspaceId: workspaceId,
            status: status,
            title: id,
            updatedAt: updatedAt,
            requiresAttention: requiresAttention,
            attentionReason: attentionReason,
            archivedAt: archivedAt,
            pendingPermissions: (0..<pendingPermissions).map { AgentPermissionRequest(id: "p\($0)") }
        )
    }

    static func workspace(
        _ id: String,
        name: String? = nil,
        projectDisplayName: String = "paseo",
        status: String = "done",
        archivingAt: String? = nil
    ) -> WorkspaceDescriptor {
        WorkspaceDescriptor(
            id: id,
            projectDisplayName: projectDisplayName,
            name: name ?? id,
            status: status,
            archivingAt: archivingAt
        )
    }

    static func host(
        _ workspaces: [WorkspaceDescriptor] = [],
        hostId: String = "h1",
        label: String? = "laptop",
        hostname: String? = nil,
        endpointHint: String = "127.0.0.1:6767",
        status: HostStatus = .connected,
        serverId: String? = "srv-1",
        agents: [AgentSnapshot] = [],
        workspacesTruncated: Bool = false,
        agentsTruncated: Bool = false
    ) -> HostSnapshot {
        HostSnapshot(
            hostId: hostId,
            label: label,
            hostname: hostname,
            endpointHint: endpointHint,
            status: status,
            serverId: serverId,
            workspaces: workspaces,
            agents: agents,
            workspacesTruncated: workspacesTruncated,
            agentsTruncated: agentsTruncated
        )
    }

    static func directEntry(
        _ id: String,
        label: String? = nil,
        endpoint: String = "127.0.0.1:6767",
        useTls: Bool = false
    ) -> HostEntry {
        .directTcp(id: id, label: label ?? id, endpoint: endpoint, useTls: useTls, password: nil)
    }

    static let relayEntry: HostEntry = .relay(
        id: "r1",
        label: "studio",
        offer: ConnectionOffer(serverId: "srv-2", daemonPublicKeyB64: "AAAA", relay: .init(endpoint: "relay.paseo.sh:443", useTls: true))
    )

    static func config(_ hosts: HostEntry...) throws -> AppConfig {
        try AppConfig.validate(hosts: hosts)
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Store/HostStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostStoreTests {
    private func seeded() -> HostStore {
        let store = HostStore()
        store.setHost("h1", label: "laptop", endpointHint: "127.0.0.1:6767")
        return store
    }

    @Test("seeds a host and reports its workspaces and agents")
    func seeds() throws {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: false)

        let host = try #require(store.snapshot().first)
        #expect(host.label == "laptop")
        #expect(host.agents.map(\.id) == ["a", "b"])
        #expect(host.workspaces.map(\.id) == ["w1"])
    }

    @Test("applies an agent upsert as a full replacement")
    func agentUpsert() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a", status: "idle")], truncated: false)
        store.applyAgentUpdate("h1", .upsert(Fixture.agent("a", status: "running")))
        #expect(store.snapshot().first?.agents.first?.status == "running")
    }

    @Test("applies a workspace upsert as a full replacement")
    func workspaceUpsert() {
        let store = seeded()
        store.seedWorkspaces("h1", [Fixture.workspace("w1", status: "done")], truncated: false)
        store.applyWorkspaceUpdate("h1", .upsert(Fixture.workspace("w1", status: "needs_input")))
        #expect(store.snapshot().first?.workspaces.first?.status == "needs_input")
    }

    @Test("applies an agent remove and a workspace remove")
    func removes() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1"), Fixture.workspace("w2")], truncated: false)
        store.applyAgentUpdate("h1", .remove(agentId: "a"))
        store.applyWorkspaceUpdate("h1", .remove(id: "w1"))
        #expect(store.snapshot().first?.agents.map(\.id) == ["b"])
        #expect(store.snapshot().first?.workspaces.map(\.id) == ["w2"])
    }

    @Test("re-seeding replaces wholesale so a subscription gap cannot strand a row")
    func reseedReplaces() {
        let store = seeded()
        store.seedAgents("h1", [Fixture.agent("a"), Fixture.agent("b")], truncated: false)
        store.seedAgents("h1", [Fixture.agent("b")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w1"), Fixture.workspace("w2")], truncated: false)
        store.seedWorkspaces("h1", [Fixture.workspace("w2")], truncated: false)
        #expect(store.snapshot().first?.agents.map(\.id) == ["b"])
        #expect(store.snapshot().first?.workspaces.map(\.id) == ["w2"])
    }

    @Test("tracks status and serverId per host")
    func statusAndServerId() {
        let store = seeded()
        #expect(store.snapshot().first?.status == .connecting)
        store.setStatus("h1", .connected)
        store.setServerId("h1", "srv-1")
        #expect(store.snapshot().first?.status == .connected)
        #expect(store.snapshot().first?.serverId == "srv-1")
    }

    @Test("tracks the daemon's hostname the same way it tracks serverId")
    func hostname() {
        let store = seeded()
        var notifications = 0
        _ = store.subscribe { notifications += 1 }

        #expect(store.snapshot().first?.hostname == nil)
        store.setHostname("h1", "build-box.local")
        #expect(store.snapshot().first?.hostname == "build-box.local")
        #expect(notifications == 1)

        // Same value again: no-op, matching setServerId and setStatus.
        store.setHostname("h1", "build-box.local")
        #expect(notifications == 1)

        store.setHostname("h1", "new-name.local")
        #expect(notifications == 2)
    }

    @Test("leaves the label nil when the entry has none, rather than inventing one")
    func noLabel() {
        let store = HostStore()
        store.setHost("h1", label: nil, endpointHint: "127.0.0.1:6767")
        #expect(store.snapshot().first?.label == nil)
        #expect(store.snapshot().first?.endpointHint == "127.0.0.1:6767")
    }

    @Test("carries each seed's truncation flag independently and clears it on a complete re-seed")
    func truncation() {
        let store = seeded()
        #expect(store.snapshot().first?.workspacesTruncated == false)
        #expect(store.snapshot().first?.agentsTruncated == false)

        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: true)
        store.seedAgents("h1", [Fixture.agent("a")], truncated: false)
        #expect(store.snapshot().first?.workspacesTruncated == true)
        #expect(store.snapshot().first?.agentsTruncated == false)

        store.seedAgents("h1", [Fixture.agent("a")], truncated: true)
        #expect(store.snapshot().first?.agentsTruncated == true)

        store.seedWorkspaces("h1", [Fixture.workspace("w1")], truncated: false)
        #expect(store.snapshot().first?.workspacesTruncated == false)
    }

    @Test("removing a host drops it entirely")
    func removeHost() {
        let store = seeded()
        store.removeHost("h1")
        #expect(store.snapshot().isEmpty)
    }

    @Test("holds a configuration error and notifies only when it changes")
    func configError() {
        let store = HostStore()
        var notifications = 0
        _ = store.subscribe { notifications += 1 }

        #expect(store.getConfigError() == nil)
        store.setConfigError("broken")
        store.setConfigError("broken")
        #expect(store.getConfigError() == "broken")
        #expect(notifications == 1)

        store.setConfigError(nil)
        #expect(store.getConfigError() == nil)
        #expect(notifications == 2)
    }

    @Test("notifies subscribers on change and stops after unsubscribe")
    func subscription() {
        let store = HostStore()
        var notifications = 0
        let unsubscribe = store.subscribe { notifications += 1 }

        store.setHost("h1", label: "laptop", endpointHint: "127.0.0.1:6767")
        #expect(notifications == 1)

        unsubscribe()
        store.setStatus("h1", .connected)
        #expect(notifications == 1)
    }

    @Test("ignores updates for unknown hosts instead of trapping")
    func unknownHost() {
        let store = HostStore()
        store.applyAgentUpdate("nope", .remove(agentId: "a"))
        store.applyWorkspaceUpdate("nope", .remove(id: "w"))
        store.seedAgents("nope", [Fixture.agent("a")], truncated: false)
        #expect(store.snapshot().isEmpty)
    }

    @Test("keeps hosts in the order they were registered, not a dictionary's order")
    func registrationOrder() {
        let store = HostStore()
        for id in ["zebra", "apple", "middle"] {
            store.setHost(id, label: id, endpointHint: "127.0.0.1:6767")
        }
        // The menu's host rows follow config order; sorting by id would put
        // "apple" first and silently reorder the footer on every render.
        #expect(store.snapshot().map(\.hostId) == ["zebra", "apple", "middle"])
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Store/HostFleetTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct HostFleetTests {
    /// Stands in for a real connection with the two store effects the fleet's
    /// bookkeeping depends on: registering the host on construction, and
    /// removing it in `close()`.
    @MainActor
    final class FakeConnections {
        private(set) var created: [(entry: HostEntry, closed: Bool)] = []
        /// Every construction and teardown, in the order they happened.
        private(set) var events: [String] = []
        var failOn: Set<String>

        init(failOn: Set<String> = []) {
            self.failOn = failOn
        }

        func make(_ entry: HostEntry, _ store: HostStore) throws -> any HostConnecting {
            if failOn.contains(entry.id) { throw FakeFailure(id: entry.id) }
            events.append("create:\(entry.id)")
            store.setHost(entry.id, label: entry.label, endpointHint: entry.endpointHint)
            let index = created.count
            created.append((entry, false))
            return FakeConnection { [weak self] in
                guard let self else { return }
                self.events.append("close:\(entry.id)")
                self.created[index].closed = true
                store.removeHost(entry.id)
            }
        }

        var ids: [String] { created.map(\.entry.id) }
        var leaked: [String] { created.filter { !$0.closed }.map(\.entry.id) }
    }

    /// A connection that records its own teardown and nothing else.
    @MainActor
    final class FakeConnection: HostConnecting {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func close() { onClose() }
    }

    struct FakeFailure: MessageError {
        let id: String
        var message: String { "cannot build a client for \(id)" }
    }

    @MainActor
    final class Harness {
        let store = HostStore()
        let connections: FakeConnections
        private(set) var failures: [[String]] = []
        private(set) var fleet: HostFleet!

        init(failOn: Set<String> = []) {
            connections = FakeConnections(failOn: failOn)
            fleet = HostFleet(
                store: store,
                onEntryFailures: { [weak self] entries in self?.failures.append(entries) },
                makeConnection: { [weak self] entry, store in
                    guard let self else { throw FakeFailure(id: entry.id) }
                    return try self.connections.make(entry, store)
                }
            )
        }

        var lastFailures: [String] { failures.last ?? [] }
    }

    @Test("keeps the rest of the fleet when one entry cannot be used")
    func isolatesBadEntry() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("good1"), Fixture.directEntry("bad"), Fixture.directEntry("good2")))

        // The entry after the bad one still connected.
        #expect(h.connections.ids == ["good1", "good2"])
        #expect(h.lastFailures == ["bad: cannot build a client for bad"])
    }

    @Test("shows the unusable host as invalid rather than hiding it")
    func showsInvalid() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad", label: "laptop")))

        let host = try #require(h.store.snapshot().first)
        #expect(host.hostId == "bad")
        #expect(host.label == "laptop")
        #expect(host.status == .invalid)
    }

    @Test("names the failure by endpoint when the unlabeled entry never reported anything else")
    func namesByEndpoint() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try AppConfig.validate(hosts: [.directTcp(id: "bad", label: nil, endpoint: "10.1.1.1:6767", useTls: false, password: nil)]))
        #expect(h.lastFailures == ["10.1.1.1:6767: cannot build a client for bad"])
    }

    @Test("refuses to build a second connection under an id that already has one")
    func duplicateId() throws {
        let h = Harness()
        // `AppConfig.validate` rejects this, so it can only arrive from a call
        // site that skipped validation. The map would otherwise overwrite the
        // first entry's connection, leaking a socket nothing can close.
        h.fleet.apply(AppConfig.unvalidated(hosts: [
            Fixture.directEntry("dup", label: "first"),
            Fixture.directEntry("dup", label: "second"),
        ]))

        #expect(h.connections.ids == ["dup"])
        #expect(h.lastFailures == ["second: a connection for host id \"dup\" already exists"])
        #expect(h.store.snapshot().first?.status == .invalid)
    }

    @Test("clears the failure list once the entries are fixed")
    func clearsFailures() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("good")))
        #expect(h.failures == [["bad: cannot build a client for bad"], []])
    }

    @Test("no-ops on a config whose host list is unchanged")
    func fingerprintGuard() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        // A distinct value with the same hosts: the registry comes back
        // through the watcher as a fresh parse, and must not churn sockets.
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))

        #expect(h.connections.ids == ["h1"])
        #expect(h.connections.leaked == ["h1"])
        #expect(h.failures.count == 1)
    }

    @Test("re-applies when the host list changes")
    func rebuildsOnChange() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", endpoint: "127.0.0.1:7000")))

        #expect(h.connections.ids == ["h1", "h1"])
        #expect(h.connections.leaked == ["h1"])
        #expect(h.store.snapshot().map(\.hostId) == ["h1"])
    }

    @Test("tears down one generation before building the next")
    func generationOrder() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("a1"), Fixture.directEntry("a2")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("b1")))

        // Each generation is a unit: every close of the old one precedes every
        // create of the new one, so no live connection is discarded unclosed.
        #expect(h.connections.events == ["create:a1", "create:a2", "close:a1", "close:a2", "create:b1"])
        #expect(h.connections.leaked == ["b1"])
        #expect(h.store.snapshot().map(\.hostId) == ["b1"])
    }

    @Test("closes the old connection before building the new one on retry")
    func retryOrder() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.retry("h1")

        #expect(h.connections.ids == ["h1", "h1"])
        #expect(h.connections.created.first?.closed == true)
        // `close()` removes the host from the store, so building the
        // replacement first would leave a live connection the store cannot see.
        #expect(h.store.snapshot().map(\.hostId) == ["h1"])
        #expect(h.connections.events == ["create:h1", "close:h1", "create:h1"])
    }

    @Test("names the host when the rebuild itself fails")
    func retryFailure() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", label: "laptop")))
        #expect(h.lastFailures.isEmpty)

        h.connections.failOn.insert("h1")
        h.fleet.retry("h1")

        // The tray shows `invalid` either way; without the report the error
        // row never says which host stopped working or why.
        #expect(h.store.snapshot().first?.status == .invalid)
        #expect(h.lastFailures == ["laptop: cannot build a client for h1"])
    }

    @Test("clears the host's failure once a retry rebuilds it")
    func retryClearsFailure() throws {
        let h = Harness(failOn: ["h1"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1", label: "laptop"), Fixture.directEntry("h2")))
        #expect(h.lastFailures == ["laptop: cannot build a client for h1"])

        h.connections.failOn.remove("h1")
        h.fleet.retry("h1")
        #expect(h.lastFailures.isEmpty)
    }

    @Test("leaves the other hosts' failures alone when one is retried")
    func retryIsolated() throws {
        let h = Harness(failOn: ["h1", "h2"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1"), Fixture.directEntry("h2")))

        h.connections.failOn.remove("h1")
        h.fleet.retry("h1")
        #expect(h.lastFailures == ["h2: cannot build a client for h2"])
    }

    @Test("ignores a host that is not in the fleet")
    func retryUnknown() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.retry("nope")
        #expect(h.connections.ids == ["h1"])
    }

    @Test("derives a direct host's web UI from its endpoint, and a relay has none")
    func webBaseUrls() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(
            Fixture.directEntry("plain", endpoint: "192.168.1.4:6767"),
            Fixture.directEntry("tls", endpoint: "daemon.example.com:443", useTls: true),
            Fixture.relayEntry
        ))

        #expect(h.fleet.webBaseUrl(for: "plain") == "http://192.168.1.4:6767")
        #expect(h.fleet.webBaseUrl(for: "tls") == "https://daemon.example.com:443")
        // A relay is a socket tunnel, not an HTTP origin, so there is no fallback.
        #expect(h.fleet.webBaseUrl(for: "r1") == nil)
        #expect(h.fleet.webBaseUrl(for: "not-a-host") == nil)
    }

    @Test("forgets a host's URL once it leaves the config")
    func forgetsUrl() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1")))
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h2")))
        #expect(h.fleet.webBaseUrl(for: "h1") == nil)
        #expect(h.fleet.webBaseUrl(for: "h2") == "http://127.0.0.1:6767")
    }

    @Test("picks the first connected direct host in config order, skipping a relay")
    func firstWebBaseUrl() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.relayEntry, Fixture.directEntry("h1", endpoint: "192.168.1.4:6767")))
        h.store.setStatus("h1", .connected)
        #expect(h.fleet.firstWebBaseUrl() == "http://192.168.1.4:6767")
    }

    @Test("skips a host whose entry never became a live connection")
    func skipsUnbuilt() throws {
        // "bad" has a good endpoint and fails for another reason, so its entry
        // would happily yield a URL. Offering it would send the user to a host
        // that never connected.
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad"), Fixture.directEntry("good", endpoint: "10.0.0.9:6767")))
        h.store.setStatus("good", .connected)
        #expect(h.fleet.firstWebBaseUrl() == "http://10.0.0.9:6767")
    }

    @Test("offers no URL unless a host is both live and a direct connection")
    func noFallback() throws {
        let h = Harness(failOn: ["bad"])
        h.fleet.apply(try Fixture.config(Fixture.directEntry("bad"), Fixture.relayEntry))
        h.store.setStatus("r1", .connected)
        #expect(h.fleet.firstWebBaseUrl() == nil)
    }

    @Test("skips connecting, disconnected, and unauthorized hosts to offer the one that is connected")
    func skipsEveryOtherStatus() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(
            Fixture.directEntry("connecting", endpoint: "10.0.0.1:6767"),
            Fixture.directEntry("down", endpoint: "10.0.0.2:6767"),
            Fixture.directEntry("locked", endpoint: "10.0.0.3:6767"),
            Fixture.directEntry("up", endpoint: "10.0.0.4:6767")
        ))
        h.store.setStatus("down", .disconnected)
        h.store.setStatus("locked", .unauthorized)
        h.store.setStatus("up", .connected)

        // Each of the three skipped statuses still yields a URL from the entry
        // alone, which would suppress the actionable `paseo://` fallback.
        #expect(h.fleet.firstWebBaseUrl() == "http://10.0.0.4:6767")
    }

    @Test("closes every live connection on shutdown")
    func closeAll() throws {
        let h = Harness()
        h.fleet.apply(try Fixture.config(Fixture.directEntry("h1"), Fixture.directEntry("h2")))
        h.fleet.closeAll()
        #expect(h.connections.leaked.isEmpty)
    }
}
```

- [ ] **Step 6: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'HostStoreTests|HostFleetTests'`
Expected: `Test run with 34 tests in 2 suites passed`.

- [ ] **Step 7: Mutate to prove the retry order bites**

In `HostFleet.retry`, swap the two statements so `connect(entry)` runs before the old connection is closed. Run the filter.
Expected: `closes the old connection before building the new one on retry` fails, because `close()` removes from the store the host the new connection had just registered. Revert and confirm green.

- [ ] **Step 8: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): replicated host store and the connection fleet

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: The tray view model

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Tray/TrayViewModel.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Tray/TrayViewModelTests.swift`

**Ports:** `src/tray/view-model.ts` and its test.

**Deliberate difference:** the TypeScript typed `workspace.status` as the bucket enum and let an unknown value fall out of the section map. Swift decodes it as a string, so the unknown case is explicit: `guard let bucket = workspace.bucket else { continue }`, and a test pins it. Same outcome, stated instead of implied.

**Interfaces:**
- Consumes `HostSnapshot`, `AgentSnapshot.statusPriority`, `WorkspaceStateBucket`.
- Produces `TrayIconState`, `TrayWorkspaceRow`, `TrayMenuSection`, `TrayHostStatus`, `TrayViewModel` (with `.empty`), `TrayViewModelBuilder.build(hosts:configError:)`, `.sectionOrder`, `.sectionLabels`, `.iconNames`, and `resolveHostName` in both its snapshot and its four-argument form.

- [ ] **Step 1: Write the source**

`PaseoIconPackage/Sources/PaseoIconCore/Tray/TrayViewModel.swift`:

```swift
import Foundation

/// The tray icon is always one bucket's icon: the highest-priority non-empty
/// one, or `done` (the Paseo mark) when there are no workspaces at all.
public typealias TrayIconState = WorkspaceStateBucket

public struct TrayWorkspaceRow: Equatable, Sendable, Identifiable {
    public let hostId: String
    public let serverId: String?
    public let workspaceId: String
    /// The agent a click opens, or nil when this workspace has none. There is
    /// no workspace deep link, so a row without an agent has no in-app target.
    public let agentId: String?
    /// The workspace's resolved display name, the same one the sidebar shows.
    public let label: String
    public let projectName: String
    /// Nil when only one host is configured.
    public let hostLabel: String?

    public var id: String { "\(hostId)/\(workspaceId)" }
}

public struct TrayMenuSection: Equatable, Sendable, Identifiable {
    public let bucket: WorkspaceStateBucket
    public let rows: [TrayWorkspaceRow]
    /// Rows dropped by the cap. Always rendered, never silent.
    public let overflow: Int

    public var id: String { bucket.rawValue }
}

public struct TrayHostStatus: Equatable, Sendable, Identifiable {
    public let hostId: String
    public let label: String
    public let status: HostStatus

    public var id: String { hostId }
}

public struct TrayViewModel: Equatable, Sendable {
    public let icon: TrayIconState
    public let count: Int
    public let sections: [TrayMenuSection]
    public let hostStatuses: [TrayHostStatus]
    /// Labels of connected hosts with more workspaces than the seed page
    /// carried. The rows below them are a subset, and the menu says so.
    public let truncatedHosts: [String]
    /// Labels of connected hosts whose agent page was capped. The rows are all
    /// there, but a click may not find its agent and falls back to the browser.
    public let agentIndexTruncatedHosts: [String]
    /// Set when the registry cannot be used; the last known-good fleet keeps running.
    public let configError: String?

    public static let empty = TrayViewModel(
        icon: .done, count: 0, sections: [], hostStatuses: [],
        truncatedHosts: [], agentIndexTruncatedHosts: [], configError: nil
    )
}

public enum TrayViewModelBuilder {
    /// Section order and labels, copied verbatim from `STATUS_BUCKET_ORDER`
    /// and `STATUS_BUCKET_LABELS` in the Paseo app's
    /// `sidebar-status-view-model.ts`. They are copied rather than invented
    /// because Paseo's glossary rule is "UI label wins, no synonyms": the tray
    /// and the sidebar describe the same workspaces. "Idle" in particular is
    /// not a Paseo state at all; a quiet workspace is `done`.
    public static let sectionOrder: [WorkspaceStateBucket] = [.needsInput, .failed, .attention, .running, .done]

    public static let sectionLabels: [WorkspaceStateBucket: String] = [
        .needsInput: "Needs input",
        .failed: "Failed",
        .attention: "Ready to review",
        .running: "Working",
        .done: "Done",
    ]

    /// The asset name for each bucket's icon.
    public static let iconNames: [WorkspaceStateBucket: String] = [
        .needsInput: "needsInput",
        .failed: "failed",
        .attention: "attention",
        .running: "running",
        .done: "done",
    ]

    /// The buckets the icon's count is drawn from. `done` is excluded: it is
    /// the resting state, so counting it would badge every quiet workspace.
    static let countedBuckets: Set<WorkspaceStateBucket> = [.needsInput, .failed, .attention]

    /// Rows in a section cap here; the rest become an explicit overflow row.
    static let sectionRowCap = 15

    public static func build(hosts: [HostSnapshot], configError: String? = nil) -> TrayViewModel {
        let showHostLabel = hosts.count > 1
        // A disconnected host's workspaces are data we cannot vouch for, so
        // they never reach the icon, the count, or the menu.
        let live = hosts.filter { $0.status == .connected }

        var rowsByBucket: [WorkspaceStateBucket: [TrayWorkspaceRow]] = [:]
        var counted = 0

        for host in live {
            let agents = agentsByWorkspace(host.agents)
            let hostName = resolveHostName(host)
            for workspace in host.workspaces {
                guard workspace.archivingAt == nil else { continue }
                // `status` is the daemon's own bucket. Nothing here recomputes
                // it: the sidebar renders the same field, and a second
                // derivation is a second answer. A bucket this build does not
                // know is dropped rather than guessed at.
                guard let bucket = workspace.bucket else { continue }
                let row = TrayWorkspaceRow(
                    hostId: host.hostId,
                    serverId: host.serverId,
                    workspaceId: workspace.id,
                    agentId: agents[workspace.id]?.first?.id,
                    label: workspace.name,
                    projectName: workspace.projectDisplayName,
                    hostLabel: showHostLabel ? hostName : nil
                )
                rowsByBucket[bucket, default: []].append(row)
                if countedBuckets.contains(bucket) { counted += 1 }
            }
        }

        let sections = sectionOrder.compactMap { bucket -> TrayMenuSection? in
            guard let rows = rowsByBucket[bucket], !rows.isEmpty else { return nil }
            if rows.count <= sectionRowCap { return TrayMenuSection(bucket: bucket, rows: rows, overflow: 0) }
            return TrayMenuSection(bucket: bucket, rows: Array(rows.prefix(sectionRowCap)), overflow: rows.count - sectionRowCap)
        }

        return TrayViewModel(
            // `sections` is already in sectionOrder and holds only non-empty
            // buckets, so its first entry is the highest-priority one. No
            // workspaces at all falls back to `done`, the resting state.
            icon: sections.first?.bucket ?? .done,
            count: counted,
            sections: sections,
            hostStatuses: hosts.map { TrayHostStatus(hostId: $0.hostId, label: resolveHostName($0), status: $0.status) },
            truncatedHosts: live.filter(\.workspacesTruncated).map(resolveHostName),
            agentIndexTruncatedHosts: live.filter(\.agentsTruncated).map(resolveHostName),
            configError: configError
        )
    }

    /// Groups a host's agents by workspace, most relevant first, so a click
    /// lands on the agent Paseo itself would call the reason the workspace is
    /// in the bucket it is in. `updatedAt` then `id` break ties, so the same
    /// fleet always resolves to the same agent.
    private static func agentsByWorkspace(_ agents: [AgentSnapshot]) -> [String: [AgentSnapshot]] {
        var grouped: [String: [AgentSnapshot]] = [:]
        for agent in agents {
            guard agent.archivedAt == nil, let workspaceId = agent.workspaceId else { continue }
            grouped[workspaceId, default: []].append(agent)
        }
        for (workspaceId, bucket) in grouped {
            grouped[workspaceId] = bucket.sorted(by: isMoreRelevant)
        }
        return grouped
    }

    private static func isMoreRelevant(_ a: AgentSnapshot, _ b: AgentSnapshot) -> Bool {
        if a.statusPriority != b.statusPriority { return a.statusPriority < b.statusPriority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }
}

/// The display name for a host: the user's explicit label if they set one,
/// else the daemon's own hostname, else its serverId, else the entry's own
/// connection endpoint as a last resort. Matches Paseo's own precedence for
/// the same decision, so a host paired here reads the way it would in Paseo.
public func resolveHostName(_ host: HostSnapshot) -> String {
    resolveHostName(label: host.label, hostname: host.hostname, serverId: host.serverId, endpointHint: host.endpointHint)
}

public func resolveHostName(label: String?, hostname: String?, serverId: String?, endpointHint: String) -> String {
    label ?? shortenHostname(hostname) ?? serverId ?? endpointHint
}

/// mDNS and default-domain suffixes, longest first so `.localdomain` wins.
private let hostnameSuffixes = [".localdomain", ".local"]

/// Drops the trailing `.local` / `.localdomain` a machine reports over mDNS:
/// `build-box.local` is the same machine as `build-box`, and the suffix is an
/// artifact of how the name is announced. Only the daemon-reported hostname
/// goes through here; an explicit label is rendered verbatim, because a user
/// who types `foo.local` means it. Returns nil when stripping would leave
/// nothing, so a host named exactly `.local` falls through to the next tier.
func shortenHostname(_ hostname: String?) -> String? {
    guard let hostname else { return nil }
    // A fully-qualified name may carry the DNS root dot; it is not part of the label.
    let trimmed = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
    let lowered = trimmed.lowercased()
    for suffix in hostnameSuffixes where lowered.hasSuffix(suffix) {
        let shortened = String(trimmed.dropLast(suffix.count))
        return shortened.isEmpty ? nil : shortened
    }
    return trimmed.isEmpty ? nil : trimmed
}
```

- [ ] **Step 2: Write the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Tray/TrayViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct TrayViewModelTests {
    private func build(_ hosts: [HostSnapshot], configError: String? = nil) -> TrayViewModel {
        TrayViewModelBuilder.build(hosts: hosts, configError: configError)
    }

    @Test("shows the Paseo mark when there are no workspaces at all")
    func emptyFleet() {
        let model = build([Fixture.host()])
        #expect(model.icon == .done)
        #expect(model.count == 0)
    }

    @Test("shows the done icon when everything is done, because done is the resting state")
    func allDone() {
        let model = build([Fixture.host([Fixture.workspace("w1"), Fixture.workspace("w2")])])
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.sections.map(\.bucket) == [.done])
    }

    @Test("shows the running icon when a workspace is running and nothing outranks it")
    func running() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "running")])])
        #expect(model.icon == .running)
        #expect(model.count == 0)
    }

    @Test("lets a counted bucket outrank running")
    func attentionOutranksRunning() {
        let model = build([Fixture.host([
            Fixture.workspace("w1", status: "running"),
            Fixture.workspace("w2", status: "attention"),
        ])])
        #expect(model.icon == .attention)
        #expect(model.count == 1)
    }

    @Test("counts needs_input, failed, and attention but never done or running")
    func countedBuckets() {
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "needs_input"),
            Fixture.workspace("b", status: "failed"),
            Fixture.workspace("c", status: "attention"),
            Fixture.workspace("d", status: "running"),
            Fixture.workspace("e", status: "done"),
        ])])
        #expect(model.count == 3)
        #expect(model.icon == .needsInput)
    }

    @Test("picks the icon of the highest-priority non-empty bucket in section order")
    func iconFollowsSectionOrder() {
        // failed, running, and done are all present; only failed outranks the
        // others in section order, so only the ordering rule can produce this.
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "done"),
            Fixture.workspace("b", status: "running"),
            Fixture.workspace("c", status: "failed"),
        ])])
        #expect(model.icon == .failed)
    }

    @Test("orders sections the way the Paseo sidebar does")
    func sectionOrder() {
        // All five buckets, supplied in an order matching none of them, so
        // every position is pinned. A section order that drifts from the
        // sidebar's defeats the whole point of listing workspaces.
        let model = build([Fixture.host([
            Fixture.workspace("e", status: "done"),
            Fixture.workspace("d", status: "running"),
            Fixture.workspace("c", status: "attention"),
            Fixture.workspace("b", status: "failed"),
            Fixture.workspace("a", status: "needs_input"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput, .failed, .attention, .running, .done])
    }

    @Test("omits sections with no workspaces in them")
    func omitsEmptySections() {
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "needs_input"),
            Fixture.workspace("e", status: "done"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput, .done])
    }

    @Test("takes the bucket from the daemon rather than deriving one")
    func daemonOwnsTheBucket() {
        // The workspace's own agent is idle and wants nothing; the daemon
        // still says `needs_input`, and the daemon wins.
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input")], agents: [Fixture.agent("a1")])])
        #expect(model.sections.map(\.bucket) == [.needsInput])
        #expect(model.count == 1)
    }

    @Test("drops a workspace whose bucket this build has never heard of, rather than guessing")
    func unknownBucket() {
        // The daemon is not version-pinned. A bucket it adds tomorrow must
        // cost that row, not the menu, and must never be counted or iconed.
        let model = build([Fixture.host([
            Fixture.workspace("w1", status: "brand_new_bucket"),
            Fixture.workspace("w2", status: "needs_input"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput])
        #expect(model.count == 1)
    }

    @Test("excludes workspaces being archived from counts and rows")
    func excludesArchiving() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input", archivingAt: "2026-08-16T00:00:00.000Z")])])
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.sections.isEmpty)
    }

    @Test("excludes a disconnected host's workspaces from counts")
    func excludesDisconnected() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input")], status: .disconnected)])
        #expect(model.icon == .done)
        #expect(model.count == 0)
    }

    @Test("carries the workspace's own name and project, not a derived label")
    func rowContent() throws {
        let model = build([Fixture.host([Fixture.workspace("w1", name: "fix-login", projectDisplayName: "paseo-menubar")])])
        let row = try #require(model.sections.first?.rows.first)
        #expect(row.label == "fix-login")
        #expect(row.projectName == "paseo-menubar")
    }

    @Test("omits the host label with a single host and includes it with two")
    func hostLabelVisibility() {
        let single = build([Fixture.host([Fixture.workspace("w1")])])
        #expect(single.sections.first?.rows.first?.hostLabel == nil)

        let multiple = build([
            Fixture.host([Fixture.workspace("w1")]),
            Fixture.host(hostId: "h2", label: "studio", serverId: "srv-2"),
        ])
        #expect(multiple.sections.first?.rows.first?.hostLabel == "laptop")
    }

    @Test("caps rows in a section at 15 and reports the overflow")
    func sectionCap() throws {
        let many = (0..<18).map { Fixture.workspace("w\($0)", status: "needs_input") }
        let model = build([Fixture.host(many)])
        let section = try #require(model.sections.first { $0.bucket == .needsInput })
        #expect(section.rows.count == 15)
        #expect(section.overflow == 3)
        // The count is the whole bucket, not the visible slice.
        #expect(model.count == 18)
    }

    @Test("names hosts whose workspace list was capped so the rows are never a silent subset")
    func truncatedHosts() {
        let model = build([
            Fixture.host([Fixture.workspace("w1")], workspacesTruncated: true),
            Fixture.host(hostId: "h2", label: "studio"),
        ])
        #expect(model.truncatedHosts == ["laptop"])
    }

    @Test("names hosts whose agent page was capped, because their click targets may be missing")
    func agentTruncatedHosts() {
        let model = build([
            Fixture.host([Fixture.workspace("w1")], agentsTruncated: true),
            Fixture.host(hostId: "h2", label: "studio"),
        ])
        #expect(model.agentIndexTruncatedHosts == ["laptop"])
        #expect(model.truncatedHosts.isEmpty)
    }

    @Test("ignores truncation on a host whose workspaces are excluded anyway")
    func truncationOnDisconnected() {
        let model = build([Fixture.host(
            [Fixture.workspace("w1")],
            status: .disconnected,
            workspacesTruncated: true,
            agentsTruncated: true
        )])
        #expect(model.truncatedHosts.isEmpty)
        #expect(model.agentIndexTruncatedHosts.isEmpty)
    }

    @Test("reports host connection state for the status footer")
    func hostStatuses() {
        let model = build([
            Fixture.host(status: .connected),
            Fixture.host(hostId: "h2", label: "studio", status: .disconnected, serverId: nil),
        ])
        #expect(model.hostStatuses == [
            TrayHostStatus(hostId: "h1", label: "laptop", status: .connected),
            TrayHostStatus(hostId: "h2", label: "studio", status: .disconnected),
        ])
    }

    @Test("carries a configuration error through to the menu, keeping the last good hosts")
    func configError() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "failed")])], configError: "registry error\n\nnot valid JSON")
        #expect(model.configError == "registry error\n\nnot valid JSON")
        #expect(model.count == 1)
    }

    @Test("has no configuration error by default")
    func noConfigError() {
        #expect(build([Fixture.host()]).configError == nil)
    }

    @Test("carries serverId on rows so a click can build a deep link")
    func rowServerId() throws {
        let row = try #require(build([Fixture.host([Fixture.workspace("w1")])]).sections.first?.rows.first)
        #expect(row.serverId == "srv-1")
        #expect(row.workspaceId == "w1")
    }
}

struct ResolveHostNameTests {
    /// Every case supplies a distinct value at every tier, so a wrong
    /// precedence picks a different string rather than one that coincides.
    private func tiers(label: String? = "explicit-label", hostname: String? = "live-hostname", serverId: String? = "srv-id") -> String {
        resolveHostName(label: label, hostname: hostname, serverId: serverId, endpointHint: "127.0.0.1:6767")
    }

    @Test("prefers the explicit label over everything else")
    func prefersLabel() {
        #expect(tiers() == "explicit-label")
    }

    @Test("falls through the tiers in order")
    func fallsThrough() {
        #expect(tiers(label: nil) == "live-hostname")
        #expect(tiers(label: nil, hostname: nil) == "srv-id")
        #expect(tiers(label: nil, hostname: nil, serverId: nil) == "127.0.0.1:6767")
    }

    @Test("pins an explicit label even once a hostname arrives")
    func labelWins() {
        #expect(tiers(label: "Local", hostname: "build-box.local") == "Local")
    }

    @Test("drops the mDNS suffix a machine announces itself with")
    func dropsSuffix() {
        func shorten(_ hostname: String) -> String { tiers(label: nil, hostname: hostname) }
        #expect(shorten("build-box.local") == "build-box")
        #expect(shorten("build-box.localdomain") == "build-box")
        #expect(shorten("AI-MBP.LOCAL") == "AI-MBP")
        // A fully-qualified name may carry the DNS root dot.
        #expect(shorten("build-box.local.") == "build-box")
    }

    @Test("strips the suffix only at the end, and only as a whole label")
    func stripsPrecisely() {
        func shorten(_ hostname: String) -> String { tiers(label: nil, hostname: hostname) }
        // Not a suffix: the machine is simply named this.
        #expect(shorten("mylocal") == "mylocal")
        // Not at the end: a real domain that happens to contain the word.
        #expect(shorten("box.local.example.com") == "box.local.example.com")
        // `.localdomain` must win over `.local`, or the result keeps a stray `domain`.
        #expect(shorten("box.localdomain") == "box")
    }

    @Test("falls through rather than rendering an empty name")
    func neverEmpty() {
        #expect(tiers(label: nil, hostname: ".local") == "srv-id")
        #expect(tiers(label: nil, hostname: "") == "srv-id")
    }

    @Test("renders an explicit label verbatim, suffix and all")
    func labelVerbatim() {
        // A user who types `foo.local` means it; only the reported hostname is shortened.
        #expect(tiers(label: "foo.local") == "foo.local")
    }
}

struct TrayViewModelHostNamingTests {
    @Test("shows the live hostname in the host status line when the entry has no label")
    func liveHostname() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(label: nil, hostname: "build-box.local", serverId: "srv_example")])
        #expect(model.hostStatuses == [TrayHostStatus(hostId: "h1", label: "build-box", status: .connected)])
    }

    @Test("falls back to the serverId when the daemon reports no hostname")
    func serverIdFallback() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(label: nil, hostname: nil, serverId: "srv_example")])
        #expect(model.hostStatuses.first?.label == "srv_example")
    }

    @Test("uses the resolved name, not the raw label, for a truncated-host line")
    func truncatedUsesResolved() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(
            [Fixture.workspace("w1")],
            label: nil,
            hostname: "build-box.local",
            workspacesTruncated: true
        )])
        #expect(model.truncatedHosts == ["build-box"])
    }

    @Test("uses the resolved name for the per-row host label with more than one host")
    func rowUsesResolved() {
        let model = TrayViewModelBuilder.build(hosts: [
            Fixture.host([Fixture.workspace("w1")], label: nil, hostname: "build-box.local"),
            Fixture.host(hostId: "h2", label: "studio", serverId: "srv-2"),
        ])
        #expect(model.sections.first?.rows.first?.hostLabel == "build-box")
    }
}

struct TrayViewModelClickTargetTests {
    private func row(_ host: HostSnapshot) -> TrayWorkspaceRow? {
        TrayViewModelBuilder.build(hosts: [host]).sections.first?.rows.first
    }

    @Test("opens the workspace's only agent")
    func onlyAgent() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: [Fixture.agent("a1")]))?.agentId == "a1")
    }

    @Test("has no target when the workspace has no agent")
    func noAgent() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: []))?.agentId == nil)
    }

    @Test("ignores agents belonging to another workspace")
    func otherWorkspace() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: [Fixture.agent("a1", workspaceId: "w2")]))?.agentId == nil)
    }

    // Every case below is arranged so the tiebreakers would pick a different
    // agent than the rule under test.
    @Test("picks the most urgent agent by the daemon's own status priority")
    func statusPriority() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-idle", status: "idle", updatedAt: "2026-08-16T03:00:00.000Z"),
            Fixture.agent("b-running", status: "running", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-errored", status: "error", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        // Last by id and oldest by updatedAt, so only priority can put it first.
        #expect(target?.agentId == "z-errored")
    }

    @Test("ranks a pending permission above an error")
    func permissionOutranksError() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-errored", status: "error", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-asking", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z", attentionReason: "permission", pendingPermissions: 1),
        ]))
        #expect(target?.agentId == "z-asking")
    }

    @Test("counts a pending permission even when the attention reason says nothing")
    func pendingPermissionCount() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-errored", status: "error", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-asking", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z", pendingPermissions: 2),
        ]))
        // The count alone is the first term of the daemon's ranking; dropping
        // the field would silently demote every agent waiting on a permission.
        #expect(target?.agentId == "z-asking")
    }

    @Test("breaks a priority tie on updatedAt, newest first, then on id")
    func tiebreakers() {
        let byTime = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-older", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("z-newer", status: "running", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        // Last by id, so only the timestamp can put it first.
        #expect(byTime?.agentId == "z-newer")

        let byId = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("b", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("a", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
        ]))
        #expect(byId?.agentId == "a")
    }

    @Test("never targets an archived agent")
    func archivedAgent() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            // More urgent and newer, so only the archive filter can exclude it.
            Fixture.agent("gone", status: "error", updatedAt: "2026-08-16T02:00:00.000Z", archivedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("live", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        #expect(target?.agentId == "live")
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'TrayViewModelTests|ResolveHostNameTests|TrayViewModelHostNamingTests|TrayViewModelClickTargetTests'`
Expected: `Test run with 41 tests in 4 suites passed`.

- [ ] **Step 4: Mutate to prove the ranking and the section order bite**

1. In `TrayViewModelBuilder.isMoreRelevant`, delete the `statusPriority` comparison so it falls straight to `updatedAt`. Expected: `picks the most urgent agent by the daemon's own status priority` and `ranks a pending permission above an error` both fail. Revert.
2. In `sectionOrder`, swap `.failed` and `.attention`. Expected: `orders sections the way the Paseo sidebar does` fails. Revert.
3. In `AgentSnapshot.statusPriority`, delete the `pendingPermissions?.count` term. Expected: `counts a pending permission even when the attention reason says nothing` fails. Revert.

Confirm green after all three.

- [ ] **Step 5: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): tray view model with the sidebar's own buckets and order

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: The menu as data, and deep links

**Files:**
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Tray/MenuModel.swift`
- Create: `PaseoIconPackage/Sources/PaseoIconCore/Launch/OpenPaseo.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Tray/MenuModelTests.swift`
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Launch/OpenPaseoTests.swift`

**Ports:** `src/tray/menu-template.ts` and `src/launch/open-paseo.ts` and their tests.

**Two deliberate differences:**

1. **The menu is data, not a template of click handlers.** `buildMenuTemplate` returned Electron menu items carrying closures; `MenuModel.build` returns `[MenuItem]`, and the SwiftUI layer attaches the actions. This is what lets the whole menu be asserted without a menu bar, and it keeps every routing decision in the core.
2. **`OpenPaseo` returns a target rather than opening it.** The TypeScript took an `openExternal` dependency; the Swift functions are pure and the coordinator owns `NSWorkspace`. The routing rules are unchanged, including the one that matters most: a workspace with no agent goes to the daemon's web route *even when the desktop app is installed*, because `paseo://h/<serverId>/workspace/<id>` parses as nothing.

**Interfaces:**
- Consumes `TrayViewModel`, `TrayWorkspaceRow`, `HostStatus`, `WorkspaceStateBucket`.
- Produces `MenuItem` (`.sectionHeading`, `.workspace`, `.overflow`, `.separator`, `.note`, `.configError`, `.hostStatus`, `.openApp`, `.loginItem`, `.quit`, each with a distinct `id`), `MenuModel.build(_:loginItemEnabled:)`, `MenuModel.rowLabel(_:)`, `OpenTarget`, `OpenAgentTarget`, `OpenWorkspaceTarget`, `OpenPaseo.app/agent/workspace/agentDeepLink/agentRoute/defaultDesktopAppInstalled/appDeepLink`.

- [ ] **Step 1: Write the sources**

`PaseoIconPackage/Sources/PaseoIconCore/Tray/MenuModel.swift`:

```swift
import Foundation

/// One row of the tray menu, as data. The SwiftUI layer renders this and
/// nothing else decides what the menu contains, so the whole menu is testable
/// without a menu bar.
public enum MenuItem: Equatable, Sendable, Identifiable {
    /// A disabled section heading carrying its bucket's icon.
    case sectionHeading(bucket: WorkspaceStateBucket, label: String)
    case workspace(row: TrayWorkspaceRow, label: String)
    /// The capped rows are only reachable in the app, so this opens it.
    case overflow(count: Int, label: String)
    case separator(index: Int)
    /// A row that does nothing but say something.
    case note(String)
    /// The fix for every configuration error is in the Paseo app.
    case configError(detail: String)
    case hostStatus(hostId: String, label: String, retryable: Bool)
    case openApp
    case loginItem(enabled: Bool)
    case quit

    public var id: String {
        switch self {
        case .sectionHeading(let bucket, _): "heading:\(bucket.rawValue)"
        case .workspace(let row, _): "row:\(row.id)"
        case .overflow(let count, _): "overflow:\(count)"
        case .separator(let index): "sep:\(index)"
        case .note(let text): "note:\(text)"
        case .configError: "configError"
        case .hostStatus(let hostId, _, _): "host:\(hostId)"
        case .openApp: "openApp"
        case .loginItem: "loginItem"
        case .quit: "quit"
        }
    }
}

public enum MenuModel {
    static let statusText: [HostStatus: String] = [
        .connecting: "connecting",
        .connected: "connected",
        .disconnected: "disconnected",
        .unauthorized: "authentication failed",
        .invalid: "invalid configuration",
    ]

    public static func rowLabel(_ row: TrayWorkspaceRow) -> String {
        var parts = [row.label, row.projectName]
        if let hostLabel = row.hostLabel { parts.append(hostLabel) }
        return parts.joined(separator: "  ·  ")
    }

    /// The whole menu, in order. Every action lives here: a menu bar item that
    /// needs a click-through for anything is an app with actions some desktops
    /// swallow.
    public static func build(_ model: TrayViewModel, loginItemEnabled: Bool) -> [MenuItem] {
        var items: [MenuItem] = []
        var separators = 0
        func separator() {
            items.append(.separator(index: separators))
            separators += 1
        }

        if let configError = model.configError {
            items.append(.configError(detail: configError))
            separator()
        }

        if model.sections.isEmpty {
            items.append(.note("No workspaces"))
        } else {
            // A rule between sections, not before the first: AppKit draws a
            // leading separator as a stray line under the menu's top edge.
            for (index, section) in model.sections.enumerated() {
                if index > 0 { separator() }
                items.append(.sectionHeading(bucket: section.bucket, label: TrayViewModelBuilder.sectionLabels[section.bucket] ?? section.bucket.rawValue))
                items.append(contentsOf: section.rows.map { .workspace(row: $0, label: rowLabel($0)) })
                if section.overflow > 0 {
                    items.append(.overflow(count: section.overflow, label: "…and \(section.overflow) more"))
                }
            }
        }

        // The seed page has a ceiling. Reaching it means these rows are a
        // subset, and a subset presented as the whole list is a silent cap.
        for label in model.truncatedHosts {
            items.append(.note("Not all workspaces shown · \(label)"))
        }
        // A capped agent page costs click targets rather than rows: a
        // workspace whose agents fell off the page opens in the browser.
        for label in model.agentIndexTruncatedHosts {
            items.append(.note("Not all agents loaded · \(label)"))
        }

        if !model.hostStatuses.isEmpty {
            separator()
            for host in model.hostStatuses {
                let text = "\(host.label) · \(statusText[host.status] ?? host.status.rawValue)"
                // Auth rejection ends the reconnect loop for good, so without
                // the retry the only way back after fixing the password is
                // relaunching the app.
                let retryable = host.status == .unauthorized
                items.append(.hostStatus(hostId: host.hostId, label: retryable ? "\(text) — retry" : text, retryable: retryable))
            }
        }

        separator()
        items.append(.openApp)
        items.append(.loginItem(enabled: loginItemEnabled))
        separator()
        items.append(.quit)
        return items
    }
}
```

`PaseoIconPackage/Sources/PaseoIconCore/Launch/OpenPaseo.swift`:

```swift
import Foundation

/// Where a click should send the user. Returned as a URL rather than opened
/// here, so the decision is pure and the app layer owns `NSWorkspace`.
public enum OpenTarget: Equatable, Sendable {
    case url(URL)
}

public struct OpenAgentTarget: Equatable, Sendable {
    public let serverId: String
    public let agentId: String
    /// Daemon HTTP base URL, used only when the desktop app is not installed.
    public let webBaseUrl: String?

    public init(serverId: String, agentId: String, webBaseUrl: String? = nil) {
        self.serverId = serverId
        self.agentId = agentId
        self.webBaseUrl = webBaseUrl
    }
}

public struct OpenWorkspaceTarget: Equatable, Sendable {
    public let serverId: String
    public let workspaceId: String
    /// The workspace's most relevant agent, chosen by the view model, or nil.
    public let agentId: String?
    /// Daemon HTTP base URL. Direct hosts have one; relay hosts do not.
    public let webBaseUrl: String?

    public init(serverId: String, workspaceId: String, agentId: String?, webBaseUrl: String? = nil) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.agentId = agentId
        self.webBaseUrl = webBaseUrl
    }
}

public enum OpenPaseo {
    /// The bare app link. macOS activates whichever app handles a scheme when
    /// a URL in it is opened, so this brings Paseo forward even though the
    /// desktop app's handler ignores links it cannot parse as an agent.
    public static let appDeepLink = URL(string: "paseo://")!

    /// The install-path probe the Paseo CLI uses for `paseo open`.
    public static func defaultDesktopAppInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/Paseo.app",
            home.appendingPathComponent("Applications/Paseo.app").path,
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// `/h/<serverId>/agent/<agentId>`, percent-encoded so an odd id cannot
    /// break the route. Copied from `buildAgentDeepLinkRoute` upstream.
    public static func agentRoute(serverId: String, agentId: String) -> String {
        "/h/\(encode(serverId))/agent/\(encode(agentId))"
    }

    public static func agentDeepLink(serverId: String, agentId: String) -> URL {
        URL(string: "paseo:/\(agentRoute(serverId: serverId, agentId: agentId))") ?? appDeepLink
    }

    /// Opens Paseo itself, with the same web fallback rule `agent` uses.
    public static func app(webBaseUrl: String?, desktopAppInstalled: Bool) -> OpenTarget {
        if !desktopAppInstalled, let webBaseUrl, let url = URL(string: trimSlashes(webBaseUrl)) {
            return .url(url)
        }
        return .url(appDeepLink)
    }

    public static func agent(_ target: OpenAgentTarget, desktopAppInstalled: Bool) -> OpenTarget {
        if !desktopAppInstalled, let webBaseUrl = target.webBaseUrl,
           let url = URL(string: trimSlashes(webBaseUrl) + agentRoute(serverId: target.serverId, agentId: target.agentId)) {
            return .url(url)
        }
        return .url(agentDeepLink(serverId: target.serverId, agentId: target.agentId))
    }

    /// Opens a workspace. There is no workspace deep link: the desktop app's
    /// handler drops what it cannot parse as an agent, so
    /// `paseo://h/<serverId>/workspace/<id>` opens nothing at all. Paseo is a
    /// separate repository and this app cannot change that, so a workspace is
    /// opened through one of its agents.
    public static func workspace(_ target: OpenWorkspaceTarget, desktopAppInstalled: Bool) -> OpenTarget {
        if let agentId = target.agentId {
            return agent(
                OpenAgentTarget(serverId: target.serverId, agentId: agentId, webBaseUrl: target.webBaseUrl),
                desktopAppInstalled: desktopAppInstalled
            )
        }

        // No agent to stand in for the workspace. The daemon's own web UI does
        // route this path, so the browser lands on the right workspace,
        // preferred over `paseo://` even with the desktop app installed, which
        // would only bring Paseo forward at whatever it happened to be showing.
        if let webBaseUrl = target.webBaseUrl,
           let url = URL(string: trimSlashes(webBaseUrl) + "/h/\(encode(target.serverId))/workspace/\(encode(target.workspaceId))") {
            return .url(url)
        }

        // A relay host with no agent in the workspace: no deep link, and no
        // HTTP origin to fall back to. Open Paseo itself rather than swallowing
        // the click, because a menu row that does nothing reads as a broken app.
        return app(webBaseUrl: nil, desktopAppInstalled: desktopAppInstalled)
    }

    /// Matches JavaScript's `encodeURIComponent`, which escapes `/` and space
    /// but leaves `-._~!*'()` alone.
    private static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func trimSlashes(_ url: String) -> String {
        var trimmed = url
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
```

- [ ] **Step 2: Write the tests**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Tray/MenuModelTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct MenuModelTests {
    private func row(workspaceId: String = "w1", agentId: String? = "a1", hostLabel: String? = nil) -> TrayWorkspaceRow {
        TrayWorkspaceRow(
            hostId: "h1",
            serverId: "srv-1",
            workspaceId: workspaceId,
            agentId: agentId,
            label: "fix-login",
            projectName: "paseo",
            hostLabel: hostLabel
        )
    }

    private func model(
        sections: [TrayMenuSection] = [],
        hostStatuses: [TrayHostStatus] = [],
        truncatedHosts: [String] = [],
        agentIndexTruncatedHosts: [String] = [],
        configError: String? = nil
    ) -> TrayViewModel {
        TrayViewModel(
            icon: .done,
            count: 0,
            sections: sections,
            hostStatuses: hostStatuses,
            truncatedHosts: truncatedHosts,
            agentIndexTruncatedHosts: agentIndexTruncatedHosts,
            configError: configError
        )
    }

    private func build(_ model: TrayViewModel, loginItemEnabled: Bool = false) -> [MenuItem] {
        MenuModel.build(model, loginItemEnabled: loginItemEnabled)
    }

    private func notes(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .note(let text) = $0 { text } else { nil } }
    }

    private func headings(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .sectionHeading(_, let label) = $0 { label } else { nil } }
    }

    @Test("shows an explicit empty state")
    func emptyState() {
        #expect(notes(build(model())).contains("No workspaces"))
    }

    @Test("labels sections with Paseo's own words")
    func sectionLabels() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .failed, rows: [row(workspaceId: "w2")], overflow: 0),
            TrayMenuSection(bucket: .attention, rows: [row(workspaceId: "w3")], overflow: 0),
            TrayMenuSection(bucket: .running, rows: [row(workspaceId: "w4")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w5")], overflow: 0),
        ]))
        #expect(headings(items) == ["Needs input", "Failed", "Ready to review", "Working", "Done"])
    }

    @Test("gives each section heading its own bucket, so the icon layer cannot swap them")
    func headingCarriesBucket() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w2")], overflow: 0),
        ]))
        let buckets = items.compactMap { item -> WorkspaceStateBucket? in
            if case .sectionHeading(let bucket, _) = item { return bucket }
            return nil
        }
        #expect(buckets == [.needsInput, .done])
    }

    @Test("rules between sections, but never above the first one")
    func separators() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .running, rows: [row(workspaceId: "w2")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w3")], overflow: 0),
        ]))
        // Shape down to the footer: heading, row, rule, heading, row, rule,
        // heading, row. A leading rule would show up in position 0.
        let shape = items.prefix(8).map { item -> String in
            switch item {
            case .separator: "---"
            case .sectionHeading(_, let label): label
            case .workspace(_, let label): label
            default: "?"
            }
        }
        #expect(shape == ["Needs input", "fix-login  ·  paseo", "---", "Working", "fix-login  ·  paseo", "---", "Done", "fix-login  ·  paseo"])
    }

    @Test("draws no rule when only one section has anything in it")
    func singleSection() {
        let items = build(model(sections: [TrayMenuSection(bucket: .done, rows: [row()], overflow: 0)]))
        if case .separator = items[0] { Issue.record("leading separator") }
        if case .separator = items[1] { Issue.record("separator after the heading") }
    }

    @Test("renders a workspace row with its project and host")
    func rowLabel() {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [row(hostLabel: "laptop")], overflow: 0)]))
        let labels = items.compactMap { item -> String? in
            if case .workspace(_, let label) = item { return label }
            return nil
        }
        #expect(labels == ["fix-login  ·  paseo  ·  laptop"])
    }

    @Test("carries the row itself so a click has its ids")
    func rowCarriesTarget() throws {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0)]))
        let target = try #require(items.compactMap { item -> TrayWorkspaceRow? in
            if case .workspace(let row, _) = item { return row }
            return nil
        }.first)
        #expect(target.workspaceId == "w1")
        #expect(target.agentId == "a1")
    }

    @Test("renders the overflow row rather than dropping rows silently")
    func overflow() {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [], overflow: 3)]))
        let overflow = items.compactMap { item -> String? in
            if case .overflow(_, let label) = item { return label }
            return nil
        }
        #expect(overflow == ["…and 3 more"])
    }

    @Test("offers a retry on an unauthorized host, whose session stopped reconnecting")
    func retryRow() throws {
        let items = build(model(hostStatuses: [
            TrayHostStatus(hostId: "h1", label: "laptop", status: .connected),
            TrayHostStatus(hostId: "h2", label: "studio", status: .unauthorized),
        ]))
        let hosts = items.compactMap { item -> (String, String, Bool)? in
            if case .hostStatus(let hostId, let label, let retryable) = item { return (hostId, label, retryable) }
            return nil
        }
        #expect(hosts.count == 2)
        #expect(hosts[0] == ("h1", "laptop · connected", false))
        #expect(hosts[1] == ("h2", "studio · authentication failed — retry", true))
    }

    @Test("surfaces a configuration error as a row carrying the message")
    func configError() throws {
        let items = build(model(configError: "registry error\n\nnot valid JSON"))
        let detail = try #require(items.compactMap { item -> String? in
            if case .configError(let detail) = item { return detail }
            return nil
        }.first)
        #expect(detail.contains("not valid JSON"))
        // First in the menu: the fix for it is what the user came for.
        #expect(items.first?.id == "configError")
    }

    @Test("names the invalid-entry status so a bad host is visible, not missing")
    func invalidStatus() {
        let items = build(model(hostStatuses: [TrayHostStatus(hostId: "h1", label: "my server", status: .invalid)]))
        let labels = items.compactMap { item -> String? in
            if case .hostStatus(_, let label, _) = item { return label }
            return nil
        }
        #expect(labels == ["my server · invalid configuration"])
    }

    @Test("names a host whose workspace list or agent page was capped")
    func truncationNotes() {
        let items = build(model(truncatedHosts: ["laptop"], agentIndexTruncatedHosts: ["studio"]))
        #expect(notes(items).contains("Not all workspaces shown · laptop"))
        #expect(notes(items).contains("Not all agents loaded · studio"))
    }

    @Test("always offers the footer actions, because a menu bar item cannot rely on click-through")
    func footer() {
        let items = build(model(), loginItemEnabled: true)
        #expect(items.contains(.openApp))
        #expect(items.contains(.loginItem(enabled: true)))
        #expect(items.contains(.quit))
        // Quit is last, and the login item reflects the state it was given.
        #expect(items.last == .quit)
        #expect(!build(model(), loginItemEnabled: false).contains(.loginItem(enabled: true)))
    }

    @Test("gives every item a distinct identity, so SwiftUI does not collapse two rows")
    func distinctIds() {
        let items = build(model(
            sections: [
                TrayMenuSection(bucket: .needsInput, rows: [row(), row(workspaceId: "w2")], overflow: 2),
                TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w3")], overflow: 0),
            ],
            hostStatuses: [TrayHostStatus(hostId: "h1", label: "laptop", status: .connected)],
            truncatedHosts: ["laptop"],
            configError: "boom"
        ))
        #expect(Set(items.map(\.id)).count == items.count)
    }
}
```

`PaseoIconPackage/Tests/PaseoIconCoreTests/Launch/OpenPaseoTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

struct OpenPaseoTests {
    private func url(_ target: OpenTarget) -> String {
        if case .url(let url) = target { return url.absoluteString }
        return ""
    }

    @Test("uses the paseo deep link for an agent when the desktop app is installed")
    func agentDeepLink() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv-1", agentId: "a1"), desktopAppInstalled: true)
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("falls back to the daemon web UI when the desktop app is absent")
    func agentWebFallback() {
        let target = OpenPaseo.agent(
            OpenAgentTarget(serverId: "srv-1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/agent/a1")
    }

    @Test("still tries the deep link when no web fallback is known")
    func agentNoFallback() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv-1", agentId: "a1"), desktopAppInstalled: false)
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("percent-encodes ids so an odd serverId cannot break the route")
    func encodesIds() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv 1", agentId: "a/1"), desktopAppInstalled: true)
        #expect(url(target) == "paseo://h/srv%201/agent/a%2F1")
    }

    @Test("probes real filesystem paths without trapping")
    func probe() {
        _ = OpenPaseo.defaultDesktopAppInstalled()
    }

    @Test("opens the workspace's agent, because there is no workspace deep link")
    func workspaceViaAgent() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: "a1"),
            desktopAppInstalled: true
        )
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("falls back to the daemon's workspace route when the workspace has no agent")
    func workspaceWebRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: nil, webBaseUrl: "http://127.0.0.1:6767/"),
            desktopAppInstalled: true
        )
        // Even with the desktop app installed: `paseo://h/srv-1/workspace/w1`
        // parses as nothing and would open a window on some other screen.
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/workspace/w1")
    }

    @Test("percent-encodes ids in the workspace route")
    func encodesWorkspaceRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv 1", workspaceId: "w/1", agentId: nil, webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv%201/workspace/w%2F1")
    }

    @Test("opens Paseo itself when there is neither an agent nor a web URL")
    func workspaceNoTarget() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: nil),
            desktopAppInstalled: true
        )
        // A relay host with no agents. Doing nothing would read as a broken menu.
        #expect(url(target) == "paseo://")
    }

    @Test("uses the agent's web route when the desktop app is absent")
    func workspaceAgentWebRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/agent/a1")
    }

    @Test("opens the app's scheme when the desktop app is installed")
    func appInstalled() {
        #expect(url(OpenPaseo.app(webBaseUrl: nil, desktopAppInstalled: true)) == "paseo://")
    }

    @Test("falls back to the daemon web UI for the app when the desktop app is absent")
    func appWebFallback() {
        #expect(url(OpenPaseo.app(webBaseUrl: "http://127.0.0.1:6767/", desktopAppInstalled: false)) == "http://127.0.0.1:6767")
    }

    @Test("still tries the scheme when no web fallback is known")
    func appNoFallback() {
        #expect(url(OpenPaseo.app(webBaseUrl: nil, desktopAppInstalled: false)) == "paseo://")
    }
}
```

- [ ] **Step 3: Run them**

Run: `swift test --package-path PaseoIconPackage --filter 'MenuModelTests|OpenPaseoTests'`
Expected: `Test run with 27 tests in 2 suites passed`.

- [ ] **Step 4: Mutate to prove the leading-separator and workspace-route rules bite**

1. In `MenuModel.build`, change `if index > 0 { separator() }` to `separator()`. Expected: `rules between sections, but never above the first one` fails. AppKit draws a leading separator as a stray line under the menu's top edge. Revert.
2. In `OpenPaseo.workspace`, move the web-route branch below a new `desktopAppInstalled` check so an installed app wins. Expected: `falls back to the daemon's workspace route when the workspace has no agent` fails. Revert.

Confirm green.

- [ ] **Step 5: Run the whole suite**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 294 tests in 28 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add PaseoIconPackage
git commit -m "feat(native): the menu as data, and Paseo deep links

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: The app: icons, the rendered label, the menu, the wiring

**Files:**
- Modify: `scripts/make-icons.mjs`
- Modify: `PaseoIconPackage/Package.swift`
- Create: `PaseoIconPackage/Sources/PaseoIcon/TrayIcons.swift`
- Create: `PaseoIconPackage/Sources/PaseoIcon/MenuBarLabel.swift`
- Create: `PaseoIconPackage/Sources/PaseoIcon/MenuContent.swift`
- Create: `PaseoIconPackage/Sources/PaseoIcon/AppCoordinator.swift`
- Replace: `PaseoIconPackage/Sources/PaseoIcon/PaseoIconApp.swift`

**Replaces:** `src/tray/tray-presenter.ts` and `src/main.ts`.

**Deliberate difference:** the Electron build set a template image plus adjacent title text on the `Tray`. `MenuBarExtra`'s label respects neither colour nor layout modifiers directly, so the glyph and the count are composed as a SwiftUI view and rasterized through `ImageRenderer` — the pattern the maintainer's own Gallager app uses. The result stays a *template* image, so it inverts with the menu bar exactly as the Electron icon and title did. Colour is now possible where it was not; parity comes first, and colour is a follow-up worth making deliberately rather than by accident.

**Interfaces:**
- Consumes everything above.
- Produces `TrayIcons.image(for:)`, `TrayIcons.preflight()`, `TrayIconError`, `MenuBarLabel(icon:count:)`, `MenuContent(items:coordinator:)`, `AppCoordinator` (`model`, `loginItemEnabled`, `start`, `stop`, `openWorkspace`, `openApp`, `retryHost`, `showConfigError`, `setLoginItem`, `quit`, `applicationSupportDirectory`), `PaseoIconApp`, `AppDelegate`.

- [ ] **Step 1: Have the icon generator write into the Swift target**

The app loads the glyphs through `Bundle.module`, so they have to live inside the target rather than beside it. Writing them from the generator, rather than copying them in a build step, keeps `swift run` and a packaged build looking at the same files.

In `scripts/make-icons.mjs`, after the `OUT` constant add:

```js
// The native app loads the tray glyphs through `Bundle.module`, so they have
// to live inside the Swift target rather than beside it. Written here rather
// than copied by a build step, so `swift run` and a packaged build see the
// same files and neither can go stale against the other.
const SWIFT_TRAY_ICONS = path.join(ROOT, "PaseoIconPackage", "Sources", "PaseoIcon", "Resources", "TrayIcons");
```

Add `await mkdir(SWIFT_TRAY_ICONS, { recursive: true });` beside the existing `mkdir(OUT, ...)`, and inside the per-scale loop, after the existing `writeFile(outFile, buffer)` and its log line:

```js
    const swiftFile = path.join(SWIFT_TRAY_ICONS, `${file}Template${suffix}.png`);
    await writeFile(swiftFile, buffer);
    console.log(`wrote ${swiftFile}`);
```

Then declare the directory as a resource. In `Package.swift`, replace the `PaseoIcon` executable target with:

```swift
        .executableTarget(
            name: "PaseoIcon",
            dependencies: ["PaseoIconCore"],
            // The same PNGs `npm run icons` rasterizes for the Electron build,
            // so both apps show the same marks. Generated, not committed.
            resources: [.copy("Resources/TrayIcons")]
        ),
```

Add the generated directory to `.gitignore`:

```
PaseoIconPackage/Sources/PaseoIcon/Resources/TrayIcons/
```

Run: `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm run icons && ls PaseoIconPackage/Sources/PaseoIcon/Resources/TrayIcons | wc -l`
Expected: `10` — five buckets at 1x and 2x.

- [ ] **Step 2: Write the app sources**

`PaseoIconPackage/Sources/PaseoIcon/TrayIcons.swift`:

```swift
import AppKit
import PaseoIconCore

/// The five bucket glyphs, as template images so they invert with the menu
/// bar. They are the same PNGs `npm run icons` rasterizes for the Electron
/// build, copied into this target's resources, so both apps show the same
/// marks rather than two vocabularies for one set of states.
@MainActor
enum TrayIcons {
    private static var cache: [WorkspaceStateBucket: NSImage] = [:]

    /// A missing file yields an empty image rather than an error, and an empty
    /// image is a status item with no visible icon: no way to open the menu,
    /// no way to quit. The icons are generated rather than committed, so this
    /// is reachable from a build that skipped `npm run icons`.
    static func image(for bucket: WorkspaceStateBucket) throws -> NSImage {
        if let cached = cache[bucket] { return cached }
        let name = TrayViewModelBuilder.iconNames[bucket] ?? bucket.rawValue
        guard let url = Bundle.module.url(forResource: "\(name)Template", withExtension: "png", subdirectory: "TrayIcons"),
              let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else {
            throw TrayIconError.missing(name)
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        cache[bucket] = image
        return image
    }

    /// Loads every bucket once, so a build missing its icons fails at launch
    /// with a name rather than showing a blank item.
    static func preflight() throws {
        for bucket in TrayViewModelBuilder.sectionOrder { _ = try image(for: bucket) }
    }
}

enum TrayIconError: MessageError {
    case missing(String)

    var message: String {
        switch self {
        case .missing(let name): "Missing tray icon: \(name)Template.png. Run `npm run icons`."
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIcon/MenuBarLabel.swift`:

```swift
import AppKit
import PaseoIconCore
import SwiftUI

/// The menu bar item itself: the bucket's glyph, plus the count when there is
/// one. `MenuBarExtra`'s label does not respect colour or layout modifiers
/// directly, so the composed view is rasterized through `ImageRenderer` and
/// handed over as an image.
///
/// The image stays a template, so it inverts with the menu bar the way the
/// Electron build's template icon and adjacent title text both did. Colour is
/// possible here in a way it was not under Electron; parity comes first.
struct MenuBarLabel: View {
    let icon: TrayIconState
    let count: Int

    var body: some View {
        if let image = Self.render(icon: icon, count: count) {
            Image(nsImage: image)
        } else {
            // Only reachable if the icons are missing, which `preflight`
            // already refuses to start on.
            Image(systemName: "circle.dashed")
        }
    }

    @MainActor
    private static func render(icon: TrayIconState, count: Int) -> NSImage? {
        guard let glyph = try? TrayIcons.image(for: icon) else { return nil }
        if count == 0 { return glyph }

        let content = HStack(spacing: 3) {
            Image(nsImage: glyph)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return glyph }
        image.isTemplate = true
        return image
    }
}
```

`PaseoIconPackage/Sources/PaseoIcon/MenuContent.swift`:

```swift
import PaseoIconCore
import SwiftUI

/// Renders the menu `MenuModel` decided on. Nothing here chooses what the menu
/// contains: every row, label, and ordering rule lives in the core, which is
/// what lets the whole menu be tested without a menu bar.
struct MenuContent: View {
    let items: [MenuItem]
    let coordinator: AppCoordinator

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .sectionHeading(let bucket, let label):
                // A disabled heading carrying its bucket's glyph, matching the
                // sidebar, which shows one per section.
                Label {
                    Text(label)
                } icon: {
                    if let image = try? TrayIcons.image(for: bucket) { Image(nsImage: image) }
                }
                .disabled(true)

            case .workspace(let row, let label):
                Button(label) { coordinator.openWorkspace(row) }

            case .overflow(_, let label):
                // The capped rows are only reachable in the app.
                Button(label) { coordinator.openApp() }

            case .separator:
                Divider()

            case .note(let text):
                Text(text)

            case .configError(let detail):
                // The fix for every one of these is in the Paseo app.
                Button("Configuration error") { coordinator.showConfigError(detail) }

            case .hostStatus(let hostId, let label, let retryable):
                if retryable {
                    Button(label) { coordinator.retryHost(hostId) }
                } else {
                    Text(label)
                }

            case .openApp:
                Button("Open Paseo") { coordinator.openApp() }

            case .loginItem(let enabled):
                Button(enabled ? "✓ Start at login" : "Start at login") {
                    coordinator.setLoginItem(!enabled)
                }

            case .quit:
                Button("Quit Paseo Icon") { coordinator.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
```

`PaseoIconPackage/Sources/PaseoIcon/AppCoordinator.swift`:

```swift
import AppKit
import PaseoIconCore
import ServiceManagement
import SwiftUI

/// Wiring, and only wiring. Every decision this reads from belongs to
/// `PaseoIconCore`: the store holds the state, the view model turns it into a
/// menu, and the registry session decides when to re-read. What lives here is
/// what genuinely needs AppKit — opening URLs, the login item, alerts — plus
/// the object graph that connects them.
@MainActor
@Observable
final class AppCoordinator {
    private(set) var model: TrayViewModel = .empty
    private(set) var loginItemEnabled = false

    @ObservationIgnored private let store = HostStore()
    @ObservationIgnored private var fleet: HostFleet!
    @ObservationIgnored private var session: RegistrySession!
    @ObservationIgnored private var watcher: RegistryWatcher!
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Renders are coalesced: a seed lands as several store writes in a row,
    /// and rebuilding the menu for each is work nobody sees.
    private static let rebuildDebounce = Duration.milliseconds(120)

    init() {
        fleet = HostFleet(
            store: store,
            onEntryFailures: { [weak self] failures in self?.session?.noteEntryFailures(failures) }
        )
        watcher = RegistryWatcher(
            resolveDir: { try PaseoRegistry.levelDbDir(appSupportDir: Self.applicationSupportDirectory()) },
            open: { dir, onChange, onError in
                try FSEventsWatch.open(directory: dir, onChange: onChange, onError: onError)
            }
        )
        session = RegistrySession(
            readRegistry: { try PaseoRegistry.read(appSupportDir: Self.applicationSupportDirectory()) },
            watch: { [weak self] onChange in self?.watcher.watch(onChange) ?? {} },
            applyConfig: { [weak self] config in self?.fleet.apply(config) },
            onConfigError: { [weak self] message in self?.store.setConfigError(message) },
            // A read that ran means the directory may exist now even if it did
            // not at launch, which is what makes installing Paseo mid-session
            // take effect on the next poll rather than never.
            afterRead: { [weak self] in self?.watcher.ensureAttached() }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        unsubscribe = store.subscribe { [weak self] in self?.scheduleRebuild() }
        refreshLoginItem()
        rebuild()
        Task { await session.start() }
    }

    func stop() {
        session?.stop()
        rebuildTask?.cancel()
        unsubscribe?()
        fleet?.closeAll()
    }

    // MARK: - Menu actions

    func openWorkspace(_ row: TrayWorkspaceRow) {
        guard let serverId = row.serverId else {
            // No `server_info` yet: there is nothing to build a link out of.
            return open(OpenPaseo.app(webBaseUrl: fleet.firstWebBaseUrl(), desktopAppInstalled: OpenPaseo.defaultDesktopAppInstalled()))
        }
        open(OpenPaseo.workspace(
            OpenWorkspaceTarget(
                serverId: serverId,
                workspaceId: row.workspaceId,
                agentId: row.agentId,
                webBaseUrl: fleet.webBaseUrl(for: row.hostId)
            ),
            desktopAppInstalled: OpenPaseo.defaultDesktopAppInstalled()
        ))
    }

    func openApp() {
        open(OpenPaseo.app(webBaseUrl: fleet.firstWebBaseUrl(), desktopAppInstalled: OpenPaseo.defaultDesktopAppInstalled()))
    }

    func retryHost(_ hostId: String) {
        fleet.retry(hostId)
    }

    func showConfigError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Paseo Icon — configuration"
        alert.informativeText = detail
        alert.addButton(withTitle: "Open Paseo")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openApp() }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // `swift run` has no bundle to register, and a user can decline in
            // System Settings. Neither is worth killing the tray over.
            report(title: "Paseo Icon — could not change the login item", detail: errorText(error))
        }
        refreshLoginItem()
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Internals

    private func refreshLoginItem() {
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rebuildDebounce)
            guard let self else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    private func rebuild() {
        model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
    }

    private func open(_ target: OpenTarget) {
        guard case .url(let url) = target else { return }
        // `paseo:` is registered only by the installed desktop app, so this can
        // fail. A menu row that silently does nothing reads as a broken app.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.report(
                    title: "Paseo Icon — could not open Paseo",
                    detail: "\(url.absoluteString)\n\n\(errorText(error))\n\nInstall the Paseo desktop app to open agents from the menu bar."
                )
            }
        }
    }

    private func report(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    /// `~/Library/Application Support`, the directory the Paseo app stores its
    /// Chromium profile under.
    nonisolated static func applicationSupportDirectory() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
    }
}
```

Replace `PaseoIconPackage/Sources/PaseoIcon/PaseoIconApp.swift` entirely:

```swift
import AppKit
import PaseoIconCore
import SwiftUI

/// The menu bar app. No window is ever created: `MenuBarExtra` in menu style
/// is the whole interface, and every action lives in the menu.
@main
struct PaseoIconApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                items: MenuModel.build(coordinator.model, loginItemEnabled: coordinator.loginItemEnabled),
                coordinator: coordinator
            )
        } label: {
            MenuBarLabel(icon: coordinator.model.icon, count: coordinator.model.count)
                .task { coordinator.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon; this app is the menu bar item. The bundle sets
        // LSUIElement too, but `swift run` has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)

        // A second copy would put a second item in the menu bar, both reading
        // the same registry. The bundle id is the lock.
        if isAlreadyRunning() {
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            try TrayIcons.preflight()
        } catch {
            // No icon means no visible item at all: nothing to click, nothing
            // to quit. Say so and exit rather than running invisibly.
            let alert = NSAlert()
            alert.messageText = "Paseo Icon — failed to start"
            alert.informativeText = errorText(error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func isAlreadyRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}
```

- [ ] **Step 3: Build it**

Run: `swift build --package-path PaseoIconPackage --product PaseoIcon`
Expected: `Build complete!`.

Then force a recompile and count warnings:

```bash
find PaseoIconPackage/Sources PaseoIconPackage/Tests -name '*.swift' -exec touch {} + && swift build --package-path PaseoIconPackage --build-tests 2>&1 | grep -c 'warning:'
```

Expected: `0`.

- [ ] **Step 4: Run the whole suite**

Run: `swift test --package-path PaseoIconPackage`
Expected: `Test run with 294 tests in 28 suites passed`. The app target has no tests of its own by design: everything it could get wrong lives in the core, and what is left is wiring plus two AppKit calls.

- [ ] **Step 5: Commit**

Do not run the app in this task; Task 12 is where a human does that.

```bash
git add PaseoIconPackage scripts/make-icons.mjs .gitignore
git commit -m "feat(native): menu bar app with the rendered label and the full menu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: The whole chain against a real daemon

**Files:**
- Create: `PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/FleetIntegrationTests.swift`

**Ports:** `src/registry/registry-session.integration.test.ts`, widened to assert the menu the chain produces rather than only the connection status.

**Interfaces:**
- Consumes `HostStore`, `HostFleet`, `RegistrySession`, `TrayViewModelBuilder`, `MenuModel`, and the `NodeHarness` and `eventually` helpers from Plan 1.

- [ ] **Step 1: Write the test**

`PaseoIconPackage/Tests/PaseoIconCoreTests/Registry/FleetIntegrationTests.swift`:

```swift
import Foundation
import Testing
@testable import PaseoIconCore

/// The whole chain the app wires, minus AppKit: a registry read feeds the
/// fleet, the fleet dials a real `@getpaseo/server` 0.4.0 daemon, and the
/// store fills until the view model has a row to show. Slow by design.
@MainActor
struct FleetIntegrationTests {
    @Test("connects the fleet to a host the registry reports, and the menu shows it")
    func endToEnd() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")
        let serverId = try daemon.string("serverId")

        let store = HostStore()
        let fleet = HostFleet(store: store, onEntryFailures: { _ in })
        let session = RegistrySession(
            readRegistry: {
                RegistrySnapshot(
                    hosts: [.directTcp(id: "srv_itest", label: "itest", endpoint: "127.0.0.1:\(port)", useTls: false, password: nil)],
                    failures: []
                )
            },
            watch: { _ in {} },
            applyConfig: { config in fleet.apply(config) },
            onConfigError: { message in store.setConfigError(message) },
            pollInterval: .zero
        )
        defer {
            session.stop()
            fleet.closeAll()
        }

        await session.start()

        #expect(await eventually(timeout: .seconds(30)) {
            store.snapshot().first(where: { $0.hostId == "srv_itest" })?.status == .connected
        })

        // A fresh daemon has no workspaces, so the menu is the empty state,
        // the host footer, and the actions: the shape a first launch shows.
        let model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.configError == nil)
        #expect(model.hostStatuses == [TrayHostStatus(hostId: "srv_itest", label: "itest", status: .connected)])
        #expect(store.snapshot().first?.serverId == serverId)

        let items = MenuModel.build(model, loginItemEnabled: false)
        #expect(items.contains(.note("No workspaces")))
        #expect(items.contains(.openApp))
        #expect(items.contains(.quit))
    }

    @Test("reports a host the registry could not map, without losing the one it could")
    func partialRegistry() async throws {
        let daemon = try await NodeHarness(script: "swift-test-daemon.mjs")
        defer { daemon.stop() }
        let port = try daemon.int("port")

        let store = HostStore()
        let fleet = HostFleet(store: store, onEntryFailures: { _ in })
        let session = RegistrySession(
            readRegistry: {
                RegistrySnapshot(
                    hosts: [.directTcp(id: "srv_itest", label: "itest", endpoint: "127.0.0.1:\(port)", useTls: false, password: nil)],
                    failures: ["Pipe only — no connection the menu bar can use"]
                )
            },
            watch: { _ in {} },
            applyConfig: { config in fleet.apply(config) },
            onConfigError: { message in store.setConfigError(message) },
            pollInterval: .zero
        )
        defer {
            session.stop()
            fleet.closeAll()
        }

        await session.start()
        #expect(await eventually(timeout: .seconds(30)) {
            store.snapshot().first?.status == .connected
        })

        // The usable host connects and the unusable one is named: neither
        // costs the other.
        let model = TrayViewModelBuilder.build(hosts: store.snapshot(), configError: store.getConfigError())
        #expect(model.hostStatuses.count == 1)
        #expect(try #require(model.configError).contains("Pipe only"))
        #expect(MenuModel.build(model, loginItemEnabled: false).first?.id == "configError")
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --package-path PaseoIconPackage --filter FleetIntegrationTests`
Expected: `Test run with 2 tests in 1 suite passed`, in about half a second per daemon. If it fails with `swift-test-daemon.mjs printed no JSON line`, run that script by hand and read its stderr; the usual cause is the root `npm install` not having run.

- [ ] **Step 3: Run everything, twice**

Run: `swift test --package-path PaseoIconPackage && swift test --package-path PaseoIconPackage`
Expected: `Test run with 296 tests in 29 suites passed` both times.

Run: `npx vitest run && npm run typecheck`
Expected: vitest green, typecheck silent. The Electron app is still here and still passing; nothing in Tasks 1 through 11 has touched it.

- [ ] **Step 4: Commit**

```bash
git add PaseoIconPackage
git commit -m "test(native): registry to menu against a real 0.4.0 daemon

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Packaging, signing, notarization

**Files:**
- Create: `scripts/native-bundle.mjs`
- Create: `scripts/native-bundle.test.mjs`
- Modify: `packaging/homebrew/paseo-menubar.rb`
- Modify: `package.json`

**Replaces:** electron-builder, `scripts/notarize-dmg.mjs`, and the space-to-hyphen rename that the manual upload used to do by hand.

**Interfaces:**
- Produces `BUNDLE_NAME`, `DISPLAY_NAME`, `BUNDLE_ID`, `MIN_MACOS`, `infoPlist({version})`, `artifactNames({version})`, `buildBundle`, `sign`, `notarize`, `makeArtifacts`.

- [ ] **Step 1: Write the script**

`scripts/native-bundle.mjs`:

```javascript
// Builds, signs, notarizes, and staples the native PaseoIcon.app, then wraps
// it in the dmg and zip the Homebrew cask downloads.
//
// This replaces electron-builder for the native app. It is a script rather
// than a build-system plugin for the same reason notarize-dmg.mjs is: the
// order matters and has to be visible. Signing happens after the bundle is
// complete, notarization after signing, stapling after Apple accepts, and the
// dmg is built from the stapled bundle — an image made before stapling ships
// an app Gatekeeper rejects.
//
// The pure parts (the Info.plist, the artifact names) are exported and tested;
// the rest shells out and is exercised by running it.

import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

/** The bundle directory name. Not the display name, and not the cask token. */
export const BUNDLE_NAME = "PaseoIcon";
export const DISPLAY_NAME = "Paseo Icon";
export const BUNDLE_ID = "br.eng.gustavo.paseo-menubar";
/**
 * The macOS floor. It is declared here and in Package.swift's `platforms`,
 * and `scripts/check-cask-macos.mjs` reads it back out of the built bundle to
 * hold the cask to it. Raising it means raising all three.
 */
export const MIN_MACOS = "14.0";

/** notarytool takes credentials on argv, so nothing here echoes its command. */
const CREDENTIAL_ENV = ["APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"];

/**
 * The bundle's Info.plist. `LSUIElement` is what keeps the app out of the
 * Dock; without it the menu bar app also owns a Dock icon it has no window
 * for.
 */
export function infoPlist({ version }) {
  if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
    throw new Error(`version must look like 1.2.3, got ${JSON.stringify(version)}`);
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleDisplayName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundleExecutable</key>
\t<string>${BUNDLE_NAME}</string>
\t<key>CFBundleIconFile</key>
\t<string>icon</string>
\t<key>CFBundleIdentifier</key>
\t<string>${BUNDLE_ID}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>${version}</string>
\t<key>CFBundleVersion</key>
\t<string>${version}</string>
\t<key>LSApplicationCategoryType</key>
\t<string>public.app-category.developer-tools</string>
\t<key>LSMinimumSystemVersion</key>
\t<string>${MIN_MACOS}</string>
\t<key>LSUIElement</key>
\t<true/>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Copyright © 2026 Gustavo Ambrozio</string>
</dict>
</plist>
`;
}

/**
 * The release asset names. The cask's `url` is built from these, and the
 * hyphens are not cosmetic: electron-builder's publisher renamed its
 * space-separated files on upload, the cask was written against those names,
 * and a manual upload has to match. Producing them hyphenated here removes
 * the rename step that nothing else validates.
 */
export function artifactNames({ version }) {
  if (!version) throw new Error("version is required");
  return {
    dmg: `Paseo-Icon-${version}-arm64.dmg`,
    zip: `Paseo-Icon-${version}-arm64-mac.zip`,
  };
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], ...options });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function runOrThrow(command, args, what, options) {
  const { code, stdout, stderr } = await run(command, args, options);
  // `args` may hold the app-specific password, so only the command is named.
  if (code !== 0) throw new Error(`${what} failed (${command} exited ${code})\n${stderr || stdout}`);
  return stdout;
}

function readCredentials() {
  const missing = CREDENTIAL_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `Cannot notarize: ${missing.join(", ")} not set. APPLE_ID is the Apple ` +
        `account email, APPLE_APP_SPECIFIC_PASSWORD an app-specific password from ` +
        `appleid.apple.com, and APPLE_TEAM_ID the 10-character team from the ` +
        `signing certificate's common name.`,
    );
  }
  return [
    "--apple-id", process.env.APPLE_ID,
    "--password", process.env.APPLE_APP_SPECIFIC_PASSWORD,
    "--team-id", process.env.APPLE_TEAM_ID,
  ];
}

/** Renders the 1024px app icon into the .icns macOS actually reads. */
async function buildIcns(root, resourcesDir) {
  const source = path.join(root, "assets", "generated", "icon.png");
  const iconset = path.join(root, "release", "native", "icon.iconset");
  await rm(iconset, { recursive: true, force: true });
  await mkdir(iconset, { recursive: true });
  for (const size of [16, 32, 128, 256, 512]) {
    await runOrThrow("sips", ["-z", String(size), String(size), source, "--out", path.join(iconset, `icon_${size}x${size}.png`)], "Rendering icon");
    await runOrThrow("sips", ["-z", String(size * 2), String(size * 2), source, "--out", path.join(iconset, `icon_${size}x${size}@2x.png`)], "Rendering icon");
  }
  await runOrThrow("iconutil", ["-c", "icns", iconset, "-o", path.join(resourcesDir, "icon.icns")], "Building icns");
}

/**
 * Assembles the bundle from a release build. The tray PNGs come from the
 * Swift package's own resource bundle, which `swift build` produces beside the
 * executable, so the app finds them through `Bundle.module` exactly as it does
 * under `swift run`.
 */
export async function buildBundle({ root, version }) {
  const out = path.join(root, "release", "native");
  const app = path.join(out, `${BUNDLE_NAME}.app`);
  await rm(app, { recursive: true, force: true });
  const macos = path.join(app, "Contents", "MacOS");
  const resources = path.join(app, "Contents", "Resources");
  await mkdir(macos, { recursive: true });
  await mkdir(resources, { recursive: true });

  await runOrThrow("swift", ["build", "-c", "release", "--package-path", "PaseoIconPackage", "--product", BUNDLE_NAME], "Building the app", { cwd: root });
  const binDir = (await runOrThrow("swift", ["build", "-c", "release", "--package-path", "PaseoIconPackage", "--show-bin-path"], "Locating the build", { cwd: root })).trim();

  await runOrThrow("cp", [path.join(binDir, BUNDLE_NAME), path.join(macos, BUNDLE_NAME)], "Copying the executable");
  // The resource bundle SwiftPM emits for the app target, carrying the tray icons.
  await runOrThrow("cp", ["-R", path.join(binDir, "PaseoIconPackage_PaseoIcon.bundle"), resources], "Copying resources");
  await writeFile(path.join(app, "Contents", "Info.plist"), infoPlist({ version }));
  await writeFile(path.join(app, "Contents", "PkgInfo"), "APPL????");
  await buildIcns(root, resources);
  await runOrThrow("plutil", ["-lint", path.join(app, "Contents", "Info.plist")], "Validating Info.plist");
  return app;
}

/**
 * Signs with the hardened runtime and a secure timestamp, both of which
 * notarization requires. Deep, because the resource bundle is inside.
 */
export async function sign(app, identity) {
  await runOrThrow("codesign", ["--force", "--deep", "--options", "runtime", "--timestamp", "--sign", identity, app], "Signing");
  await runOrThrow("codesign", ["--verify", "--strict", "--deep", app], "Verifying the signature");
}

/**
 * Submits, waits, and staples. Apple accepting the submission is not the same
 * as the ticket being attached, so both are read back off the finished bundle.
 */
export async function notarize(app, out) {
  const credentials = readCredentials();
  const zip = path.join(out, "notarize.zip");
  await runOrThrow("ditto", ["-c", "-k", "--keepParent", app, zip], "Zipping for notarization");
  console.log(`submitting ${path.basename(app)} to Apple; this waits on their queue`);
  const output = await runOrThrow("xcrun", ["notarytool", "submit", zip, ...credentials, "--wait"], "Notarizing");
  // notarytool exits 0 for a submission that finished but was rejected, so the
  // status line is what actually decides.
  if (!/status:\s*Accepted/i.test(output)) throw new Error(`Apple did not accept the app:\n${output}`);
  await runOrThrow("xcrun", ["stapler", "staple", app], "Stapling");
  await runOrThrow("xcrun", ["stapler", "validate", app], "Validating the staple");
  await runOrThrow("spctl", ["-a", "-t", "exec", "-vv", app], "Gatekeeper assessment");
  await rm(zip, { force: true });
}

/** The dmg and zip, built from the stapled bundle, never before it. */
export async function makeArtifacts({ app, out, version }) {
  const names = artifactNames({ version });
  const dmg = path.join(out, names.dmg);
  const zip = path.join(out, names.zip);
  await rm(dmg, { force: true });
  await rm(zip, { force: true });

  const staging = path.join(out, "dmg-staging");
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  await runOrThrow("cp", ["-R", app, path.join(staging, path.basename(app))], "Staging the dmg");
  await runOrThrow("ln", ["-s", "/Applications", path.join(staging, "Applications")], "Linking Applications");
  await runOrThrow("hdiutil", ["create", "-volname", DISPLAY_NAME, "-srcfolder", staging, "-ov", "-format", "UDZO", dmg], "Building the dmg");
  await rm(staging, { recursive: true, force: true });

  // The zip carries the stapled bundle as-is; `ditto` preserves the signature.
  await runOrThrow("ditto", ["-c", "-k", "--keepParent", app, zip], "Building the zip");
  return { dmg, zip };
}

// Usage: node scripts/native-bundle.mjs --version 0.4.0 [--identity "Developer ID Application: ..."] [--skip-notarize]
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = new Map();
  for (let i = 2; i < process.argv.length; i++) {
    const flag = process.argv[i];
    if (!flag.startsWith("--")) continue;
    const next = process.argv[i + 1];
    if (next && !next.startsWith("--")) {
      args.set(flag.slice(2), next);
      i++;
    } else {
      args.set(flag.slice(2), true);
    }
  }

  const root = process.cwd();
  const version = args.get("version") ?? JSON.parse(await readFile(path.join(root, "package.json"), "utf8")).version;
  const out = path.join(root, "release", "native");
  await mkdir(out, { recursive: true });

  const app = await buildBundle({ root, version });
  console.log(`built ${app}`);

  const identity = args.get("identity") ?? process.env.CODESIGN_IDENTITY;
  if (!identity) {
    // Unsigned is a legitimate local build; shipping one is not, so it says so.
    console.log("no --identity and no CODESIGN_IDENTITY: leaving the bundle unsigned, which is fine locally and never shippable");
    process.exit(0);
  }
  await sign(app, identity);
  console.log("signed");

  if (args.get("skip-notarize")) {
    console.log("--skip-notarize: stopping before Apple");
    process.exit(0);
  }
  await notarize(app, out);
  console.log("notarized and stapled");

  const { dmg, zip } = await makeArtifacts({ app, out, version });
  console.log(`wrote ${path.basename(dmg)} and ${path.basename(zip)}`);
}
```

- [ ] **Step 2: Write its test**

`scripts/native-bundle.test.mjs`:

```javascript
import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { BUNDLE_ID, BUNDLE_NAME, DISPLAY_NAME, MIN_MACOS, artifactNames, infoPlist } from "./native-bundle.mjs";
import { MACOS_SYMBOLS, assertCaskMatchesBundle, caskMacOSSymbol } from "./check-cask-macos.mjs";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const CASK_PATH = path.join(ROOT, "packaging", "homebrew", "paseo-menubar.rb");

describe("infoPlist", () => {
  it("declares the bundle the cask installs and the id the cask quits", () => {
    const plist = infoPlist({ version: "0.4.0" });
    expect(plist).toContain(`<key>CFBundleExecutable</key>\n\t<string>${BUNDLE_NAME}</string>`);
    expect(plist).toContain(`<key>CFBundleIdentifier</key>\n\t<string>${BUNDLE_ID}</string>`);
    expect(plist).toContain(`<key>CFBundleName</key>\n\t<string>${DISPLAY_NAME}</string>`);
  });

  it("marks the app as an agent, so it has no Dock icon", () => {
    // Without this the menu bar app also owns a Dock icon it has no window for.
    expect(infoPlist({ version: "0.4.0" })).toContain("<key>LSUIElement</key>\n\t<true/>");
  });

  it("carries the version into both version keys", () => {
    const plist = infoPlist({ version: "1.2.3" });
    expect(plist).toContain("<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>");
    expect(plist).toContain("<key>CFBundleVersion</key>\n\t<string>1.2.3</string>");
  });

  it("refuses a version that is not three numbers", () => {
    // A malformed version reaches the cask's url and produces a 404 release
    // asset, which is only discovered by a user's failed install.
    expect(() => infoPlist({ version: "v1.2" })).toThrow(/1\.2\.3/);
    expect(() => infoPlist({})).toThrow(/1\.2\.3/);
  });

  it("declares the macOS floor the cask is held to", () => {
    expect(infoPlist({ version: "0.4.0" })).toContain(`<key>LSMinimumSystemVersion</key>\n\t<string>${MIN_MACOS}</string>`);
  });
});

describe("artifactNames", () => {
  it("names the assets with hyphens, the way the cask's url spells them", () => {
    // The cask downloads this exact name. electron-builder's publisher used to
    // rename its space-separated files on upload; producing them hyphenated
    // removes the rename step that nothing else validates.
    expect(artifactNames({ version: "0.4.0" })).toEqual({
      dmg: "Paseo-Icon-0.4.0-arm64.dmg",
      zip: "Paseo-Icon-0.4.0-arm64-mac.zip",
    });
  });

  it("requires a version", () => {
    expect(() => artifactNames({})).toThrow(/version/);
  });
});

describe("the cask and the native bundle agree", () => {
  it("installs the bundle this script builds", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // Renaming the bundle breaks every `brew install` with "unable to locate
    // app", long after the release ships.
    expect(cask).toContain(`  app "${BUNDLE_NAME}.app"\n`);
  });

  it("quits the bundle id this script declares", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // The app holds a menu bar item and no window, so a plain uninstall would
    // leave it running.
    expect(cask).toContain(`uninstall quit: "${BUNDLE_ID}"`);
  });

  it("requires the macOS this bundle declares", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    // The same comparison `npm run dist` runs against the built bundle, done
    // here against the plist this script would write, so a floor raised in
    // Package.swift and here fails the suite rather than a user's install.
    expect(assertCaskMatchesBundle(cask, infoPlist({ version: "0.4.0" }))).toEqual({
      floor: MIN_MACOS,
      symbol: MACOS_SYMBOLS.get(MIN_MACOS.split(".")[0]),
    });
  });

  it("names a macOS symbol check-cask-macos knows", async () => {
    const symbol = caskMacOSSymbol(await readFile(CASK_PATH, "utf8"));
    expect([...MACOS_SYMBOLS.values()]).toContain(symbol);
  });

  it("downloads the asset names this script produces", async () => {
    const cask = await readFile(CASK_PATH, "utf8");
    const version = cask.match(/^\s*version\s+"([^"]+)"$/m)?.[1];
    expect(version).toBeDefined();
    // The url interpolates #{version}; compare the rendered tail.
    expect(cask).toContain(artifactNames({ version: "VERSION" }).dmg.replace("VERSION", '#{version}'));
  });
});
```

- [ ] **Step 3: Move the cask to the native bundle's floor**

The native app requires macOS 14 where the Electron build required 13, because it uses the Observation framework. In `packaging/homebrew/paseo-menubar.rb` change `depends_on macos: :ventura` to `depends_on macos: :sonoma`, and rewrite the comment above it to name where the floor now comes from:

```ruby
  # LSMinimumSystemVersion in the built bundle is 14.0, declared in two places
  # that have to agree: `platforms` in PaseoIconPackage/Package.swift, and
  # MIN_MACOS in scripts/native-bundle.mjs, which writes the Info.plist. The
  # floor is 14 rather than the 13 the Electron build inherited because the app
  # uses the Observation framework.
  #
  # Two checks hold this symbol to that floor. scripts/native-bundle.test.mjs
  # compares it against the plist the packaging script would write, so a floor
  # raised without this line fails the suite; scripts/check-cask-macos.mjs
  # repeats the comparison against the real built bundle during packaging. The
  # failure they prevent is invisible to the maintainer: the cask installs
  # happily on the older macOS and the app then refuses to launch, on someone
  # else's machine.
  #
  # The bare symbol reads as "exactly Sonoma" but Homebrew resolves it to a
  # minimum -- `brew info` reports "macOS >= 14" -- and the `">= :sonoma"`
  # spelling is deprecated.
  depends_on macos: :sonoma
```

Update the three annotated lines in the file's header comment so they name the native sources rather than electron-builder: `app` now comes from `BUNDLE_NAME` in `scripts/native-bundle.mjs` and is asserted by `native-bundle.test.mjs`; the `depends_on macos` line tracks `MIN_MACOS`; and the `url` no longer describes a rename, because the script writes the hyphenated names directly. Update the `zap` comment too: the app keeps no state of its own beyond the login-item registration.

- [ ] **Step 4: Add the script to package.json**

In `"scripts"`, add:

```json
    "dist:native": "node scripts/native-bundle.mjs",
```

- [ ] **Step 5: Run the tests**

Run: `npx vitest run scripts/native-bundle.test.mjs`
Expected: `Tests  12 passed (12)`.

Run: `npx vitest run`
Expected: all green. `check-cask-macos.test.mjs` still passes because `:sonoma` is in its symbol table.

- [ ] **Step 6: Build an unsigned bundle to prove the assembly**

Run: `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm run icons && node scripts/native-bundle.mjs --version 0.4.0`
Expected: `built .../release/native/PaseoIcon.app`, then a line saying it is leaving the bundle unsigned.

Check what it assembled:

```bash
plutil -p release/native/PaseoIcon.app/Contents/Info.plist | grep -E 'LSUIElement|LSMinimumSystemVersion|CFBundleIdentifier'
ls release/native/PaseoIcon.app/Contents/Resources
node scripts/check-cask-macos.mjs --app release/native/PaseoIcon.app
```

Expected: `LSUIElement => 1`, `LSMinimumSystemVersion => "14.0"`, the bundle id, a `Resources` directory holding `icon.icns` and `PaseoIconPackage_PaseoIcon.bundle`, and `cask requires macOS 14.0 (:sonoma), matching the built bundle`.

- [ ] **Step 7: Sign and notarize, if the credentials are present**

This step needs the Developer ID certificate in the login keychain and `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` in the environment. If any is missing, say so plainly and skip to Step 8 — do not claim a notarized build you did not produce.

```bash
node scripts/native-bundle.mjs --version 0.4.0 \
  --identity "$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
```

Expected, in order: `built`, `signed`, `submitting … to Apple; this waits on their queue`, `notarized and stapled`, `wrote Paseo-Icon-0.4.0-arm64.dmg and Paseo-Icon-0.4.0-arm64-mac.zip`. Apple's queue took about two minutes when this was verified.

Then read the result back off the artifacts rather than trusting the exit codes:

```bash
spctl -a -t exec -vv release/native/PaseoIcon.app
xcrun stapler validate release/native/PaseoIcon.app
ls -lh release/native/*.dmg release/native/*.zip
```

Expected: `accepted`, `source=Notarized Developer ID`, `The validate action worked!`, and both artifacts present.

- [ ] **Step 8: Commit**

```bash
git add scripts/native-bundle.mjs scripts/native-bundle.test.mjs packaging/homebrew/paseo-menubar.rb package.json
git commit -m "build(native): sign, notarize, and package the Swift app

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: The cutover

**This task is gated on a human.** Everything before it is additive: the Electron app still builds, still tests, still ships. This one deletes it. Do not start until the maintainer has run the native app and confirmed all four checks in Step 1, and do not treat a passing test suite as a substitute for them — no agent can see a menu bar.

**Files:**
- Delete: `src/**`, `electron-builder.yml`, `scripts/notarize-dmg.mjs`, `tsconfig.json`
- Modify: `package.json`, `scripts/render-cask.test.mjs`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: The human checks**

The maintainer runs these and reports what they saw. Each one is something no test in this repository can reach.

```bash
open release/native/PaseoIcon.app
```

1. **The item appears** in the menu bar, with no Dock icon, showing the bucket glyph and, if any workspace needs attention, a count beside it.
2. **The menu is right**: the same sections, in the same order, with the same labels as the Electron app, the same workspace rows, and the host footer at the bottom.
3. **A row opens the right thing**: clicking a workspace opens that workspace's agent in Paseo.
4. **The login item works**: "Start at login" toggles, and the checkmark survives quitting and reopening the app.

Record the answers in the commit message. If any of them is wrong, stop: that is a bug to fix in the tasks above, not something to carry through a cutover.

Note that the native app and the Electron app share a bundle id, so the single-instance guard means they cannot both run. Quit the Electron one first.

- [ ] **Step 2: Delete the Electron app**

```bash
git rm -r src
git rm electron-builder.yml scripts/notarize-dmg.mjs tsconfig.json
```

- [ ] **Step 3: Repoint the tooling**

`scripts/make-registry-fixtures.mjs` writes to two trees after Task 2, and one of them is the `src/` you just deleted — left alone it would recreate it on the next run. Drop the TypeScript half: delete the `root` constant and its `cp` to `swiftRoot`, and write directly to the Swift fixtures directory instead, renaming `swiftRoot` to `root`. Its header comment about Chromium's key framing stays; the line about writing to both suites goes.

Run: `node scripts/make-registry-fixtures.mjs && git status --short src 2>/dev/null` — expected: the six fixture directories rewritten under `PaseoIconPackage/`, and no `src/` recreated.

`scripts/check-cask-macos.mjs` and `scripts/render-cask.mjs` each open with a comment explaining that they live in `scripts/` rather than `src/` because `src/` is compiled into the asar. There is no asar and no `src/` any more; reword both to say they are build tooling that never ships. `scripts/swift-test-daemon.mjs` refers to `src/daemon/daemon-harness.ts` as the thing it mirrors — change that to name this plan instead, since the file it points at is gone.

In `vitest.config.ts`, drop the `src` glob so only `scripts/**/*.test.mjs` remains, and say why:

```ts
    // The app is Swift; `swift test --package-path PaseoIconPackage` is its
    // suite. What is left here is the build tooling under scripts/.
    include: ["scripts/**/*.test.mjs"],
```

In `package.json`: delete `main`, `build`, `start`, `dist`, `check:cask-macos`, and `notarize:dmg`; rename `dist:native` to `dist`; point `test` at both suites; and drop the dependencies nothing imports any more — `electron`, `electron-builder`, `@getpaseo/client`, `@getpaseo/protocol`, `snappyjs`, `zod`, `@types/snappyjs`. Keep `@getpaseo/server`, `pino`, `tweetnacl`, `ws`, `classic-level`, `sharp`, `lucide-static`, `vitest`, and `typescript`: the first four are what the Swift integration harnesses run against, and the rest generate fixtures and icons or check the scripts.

```json
    "test": "vitest run && swift test --package-path PaseoIconPackage",
    "dist": "node scripts/native-bundle.mjs",
```

Run `SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install` to prune the lockfile.

Both TypeScript configs point at `src/`, which is about to be gone. `tsconfig.json` exists to compile the Electron app into `dist/` and has no remaining job, so delete it and make `tsconfig.typecheck.json` stand alone over the build tooling:

```json
{
  // The app is Swift. What is left to typecheck is the build tooling under
  // scripts/, which is plain .mjs and never compiled into anything.
  "compilerOptions": {
    "target": "ES2023",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "noEmit": true,
    "allowJs": true,
    "checkJs": false
  },
  "include": ["scripts/**/*.mjs"],
  "exclude": []
}
```

`git rm tsconfig.json` and drop `dist/` from `.gitignore` while you are there, since nothing writes it any more.

In `scripts/render-cask.test.mjs`, the two assertions in `describe("the cask and electron-builder agree")` read `electron-builder.yml`, which is gone. Replace that block with one that reads the same facts from their new home:

```js
// The cask names the bundle directory and the repository it downloads from.
// Both now come from scripts/native-bundle.mjs and package.json; renaming
// either breaks every `brew install` long after the release ships.
describe("the cask and the packaging script agree", () => {
  it("installs the bundle the packaging script builds", async () => {
    expect(await template()).toContain(`  app "${BUNDLE_NAME}.app"\n`);
  });

  it("publishes to the repo the cask downloads from", async () => {
    const pkg = JSON.parse(await readFile(path.join(ROOT, "package.json"), "utf8"));
    const repo = pkg.repository?.url?.match(/github\.com[:/]([^/]+)\/([^/.]+)/);
    expect(repo).not.toBeNull();
    expect(await template()).toContain(`https://github.com/${repo[1]}/${repo[2]}/releases/download/`);
  });
});
```

importing `BUNDLE_NAME` from `./native-bundle.mjs`, and add a `repository` field to `package.json` if it has none:

```json
  "repository": { "type": "git", "url": "git+https://github.com/gpambrozio/paseo-menubar.git" },
```

- [ ] **Step 4: Repoint the workflows**

In `.github/workflows/ci.yml`, keep `macos-14` and the Node setup — the Swift integration tests spawn `node` — and add the Swift build. Replace the final step with:

```yaml
      - run: npm run typecheck
      - run: npx vitest run
      - run: swift test --package-path PaseoIconPackage
```

In `.github/workflows/release.yml`, replace `npm run dist` with the native script and drop `CSC_LINK`/`CSC_KEY_PASSWORD` from the environment: `codesign` reads the certificate from the runner's keychain, which the workflow would have to import separately, and the three `APPLE_*` variables are what notarization needs. Update the `HAVE_SIGNING_CREDENTIALS` guard to test the secrets the native path actually uses, and update the skip notice to name `npm run dist` as the manual path. The known issue that the repository has no Actions secrets is unchanged: a `v*` tag still cannot produce a signed build on CI.

- [ ] **Step 5: Rewrite the documentation**

`CLAUDE.md` is the file most likely to be read next and most likely to be wrong. Rewrite these parts:

- The opening line: the app is a Swift package, not Electron.
- The spec table: add the native design doc as binding, mark this plan historical, and note that the two earlier design docs still govern behaviour.
- "Where logic goes": replace the `src/` module table with the `PaseoIconCore` one from this plan's File Structure section, and restate the rule as **if it does not touch AppKit or SwiftUI, it does not belong in the app target**.
- "Critical rules": drop the Electron-specific ones (`BrowserWindow`, the SDK pin as an npm dependency) and replace them with the wire pin, the `@MainActor` rule, and the injection rule. Keep every behavioural rule: never derive a bucket, no silent caps, never crash the tray, hosts come only from the registry, the LevelDB reader never takes the lock, one bad profile never costs another host.
- "Working here": the commands from this plan.
- "Distribution": `npm run dist` is now the native script; the cask's floor is Sonoma and where it is declared.
- "Known issues": drop the electron-builder ones (`latest-mac.yml`, the blockmap, the asset-name hyphens — the script writes hyphenated names now). Keep the 200-agent cap and the missing Actions secrets. Add: the app and the Electron build shared a bundle id, so an installed copy of the old app must be replaced rather than run alongside.

The command block becomes:

```bash
SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install   # Homebrew libvips breaks sharp's prebuild
npm test                                    # vitest (scripts) + swift test
swift test --package-path PaseoIconPackage  # 296 Swift tests, 29 suites
npx vitest run                              # 42 tests, 4 files
npm run typecheck
npm run icons                               # tray glyphs and the app icon
npm run fixtures:registry                   # LevelDB fixtures, written to both suites
npm run fixtures:e2ee                       # the tweetnacl E2EE vectors
npm run dist                                # build, sign, notarize, staple, dmg + zip
PASEO_ICON_RELAY_E2E=1 swift test --package-path PaseoIconPackage --filter RelayEndToEndTests
swift run --package-path PaseoIconPackage PaseoIconProbe --offer '<pairing url>'
```

In `README.md`, update anything that says Electron, and the macOS requirement: 14, not 13.

- [ ] **Step 6: Run everything**

```bash
npm test
npm run typecheck
npx vitest run
```

Expected: 296 Swift tests in 29 suites, 42 vitest tests in 4 files, typecheck silent. The vitest number is the scripts suites only; it drops from 269 because the Electron tests went with the Electron app, and that drop is the point rather than a regression.

Confirm nothing references the deleted tree:

```bash
grep -rn "electron" --include='*.json' --include='*.yml' --include='*.mjs' --include='*.ts' . | grep -v node_modules | grep -v package-lock
```

Expected: no hits outside documentation that deliberately mentions the history.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(native)!: replace the Electron app with the Swift one

The native app reads the same registry, shows the same five buckets with the
same labels and order, opens the same deep links, and ships through the same
cask. The Electron sources, electron-builder, and the dmg notarizer are gone;
the macOS floor rises from 13 to 14.

Verified by hand: <what the maintainer saw in Step 1>.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## What this plan does not do

Named so they are choices rather than omissions.

- **Colour in the menu bar.** The label is a template image, matching the Electron build. A coloured attention state is now one `ImageRenderer` call away and is the obvious first thing to do after parity.
- **A popover or a preferences window.** `MenuBarExtra` in menu style covers everything the Electron menu did. Anything richer wants `openWindow` and a decision about what goes in it.
- **Notifications, agent actions, a shared host registry.** Deferred in the original design and still deferred.
- **Intel or universal builds.** Releases stay `arm64`.
- **An auto-updater.** Nothing reads `latest-mac.yml` today, and the script does not write one.
