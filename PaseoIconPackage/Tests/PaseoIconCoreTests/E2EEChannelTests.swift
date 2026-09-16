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

    @Test("connecting again after a close starts a fresh handshake and forwards the next close")
    func reconnectResetsState() throws {
        let h = try Harness()
        h.base.simulateOpen()
        h.channel.send(.text("queued on the first socket"))
        h.base.simulateClose(code: 1006, reason: "gone")
        #expect(h.recorder.closes.count == 1)

        h.channel.connect()
        h.base.simulateOpen()
        let firstKey = try jsonObject(h.base.sentText[0])["key"] as? String
        let secondKey = try jsonObject(try #require(h.base.sentText.last))["key"] as? String
        #expect(secondKey != nil)
        #expect(firstKey != secondKey, "a fresh key pair per socket")
        h.ready()
        #expect(h.base.sentText.count == 2, "the frame queued on the first socket is not replayed on the second")

        h.base.simulateClose(code: 1006, reason: "gone again")
        #expect(h.recorder.closes.count == 2)
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
