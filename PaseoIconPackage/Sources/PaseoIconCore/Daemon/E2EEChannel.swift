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
/// A channel may be connected again after its base closed: `connect()` resets every per-socket field, so the next socket gets a fresh key pair and a fresh close.
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
        retryTask?.cancel()
        retryTask = nil
        closeForwarded = false
        pendingSends = []
        binaryCiphertext = false
        sharedKey = nil
        helloText = ""
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

    /// A fatal frame is reported to the owner as a 1011 close: emit the error, close the
    /// base transport, then forward that close through `handleBaseClose` immediately.
    /// `URLSessionWebSocketTransport` never calls `onClose` for a close it initiated
    /// itself, so without this the owner would not learn of the disconnect until the
    /// next liveness timeout.
    private func fail(_ message: String) {
        onError?(message)
        retryTask?.cancel()
        retryTask = nil
        state = .closed
        base.close(code: Self.fatalCloseCode, reason: message)
        handleBaseClose(TransportClose(code: Self.fatalCloseCode, reason: message))
    }

    private static func parseHandshake(_ text: String) -> HandshakeMessage? {
        try? JSONDecoder().decode(HandshakeMessage.self, from: Data(text.utf8))
    }
}
