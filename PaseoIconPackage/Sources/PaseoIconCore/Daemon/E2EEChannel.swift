import Foundation

/// Paseo's client secure channel. It offers Noise and legacy with separate
/// ephemeral keys, then retries the same hello until the daemon attaches.
/// Each WebSocket connection starts with fresh handshake and record state.
@MainActor
public final class E2EEChannel: DaemonTransport {
    public static let handshakeRetryInterval: Duration = .seconds(1)
    public static let maxPendingSends = 200
    public static let fatalCloseCode = 1011
    private static let protectedHandshakeFailedCloseCode = 4002
    private static let protectedRecordFailedCloseCode = 4003

    private enum State { case idle, handshaking, open, closed }

    private struct HandshakeType: Decodable { let type: String }

    private struct ProtectedEnvelope: Codable {
        static let version = 1
        let v: Int
        let message: String
    }

    private struct ReadyMessage: Decodable {
        private enum CodingKeys: String, CodingKey { case capabilities, protected }
        private enum CapabilityKeys: String, CodingKey { case binaryCiphertext }
        let binaryCiphertext: Bool
        let protectedEnvelope: ProtectedEnvelope?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.capabilities) {
                let capabilities = try container.nestedContainer(keyedBy: CapabilityKeys.self, forKey: .capabilities)
                binaryCiphertext = capabilities.contains(.binaryCiphertext)
                    ? try capabilities.decode(Bool.self, forKey: .binaryCiphertext)
                    : false
            } else {
                binaryCiphertext = false
            }
            protectedEnvelope = container.contains(.protected)
                ? try container.decode(ProtectedEnvelope.self, forKey: .protected)
                : nil
        }
    }

    private struct HelloMessage: Encodable {
        struct Capabilities: Encodable { let binaryCiphertext = true }
        let type = "e2ee_hello"
        let key: String
        let capabilities = Capabilities()
        let protected: ProtectedEnvelope
    }

    public var onOpen: (() -> Void)?
    public var onFrame: ((TransportFrame) -> Void)?
    public var onClose: ((TransportClose) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var securityMode: RelaySecurityMode?
    private(set) var securityFailureReason: String?
    private(set) var localCloseReason: String?

    private let base: any DaemonTransport
    private let daemonPublicKey: [UInt8]
    private let clock: any Clock<Duration>
    private var minimumMode: RelaySecurityMode
    private var state: State = .idle
    private var sharedKey: E2EESharedKey?
    private var noise: NoiseNKInitiator?
    private var protectedCodec: ProtectedRecordCodec?
    private var helloText = ""
    private var binaryCiphertext = false
    private var pendingSends: [TransportFrame] = []
    private var retryTask: Task<Void, Never>?
    private var closeForwarded = false

    public init(
        base: any DaemonTransport,
        daemonPublicKeyB64: String,
        clock: any Clock<Duration>,
        minimumMode: RelaySecurityMode = .legacy
    ) throws {
        self.base = base
        self.daemonPublicKey = try E2EEBox.importPublicKey(base64: daemonPublicKeyB64)
        self.clock = clock
        self.minimumMode = minimumMode
    }

    /// True once `e2ee_ready` has passed negotiation.
    public var isOpen: Bool { state == .open }

    public func connect() {
        retryTask?.cancel()
        retryTask = nil
        closeForwarded = false
        pendingSends = []
        binaryCiphertext = false
        sharedKey = nil
        noise = nil
        protectedCodec = nil
        securityMode = nil
        securityFailureReason = nil
        localCloseReason = nil
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
            if let protectedCodec {
                do {
                    base.send(try protectedCodec.seal(frame))
                } catch {
                    failProtectedRecord("Protected relay record encryption failed")
                }
                return
            }
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
        clearConnection()
        base.close(code: code, reason: reason)
    }

    // MARK: - Base transport events

    private func handleBaseOpen() {
        guard state == .idle else { return }
        do {
            let pair = try E2EEBox.generateKeyPair()
            sharedKey = try E2EEBox.deriveSharedKey(ourSecretKey: pair.secretKey, peerPublicKey: daemonPublicKey)
            let noise = try NoiseNKInitiator(remoteStatic: daemonPublicKey)
            self.noise = noise
            let hello = HelloMessage(
                key: E2EEBox.exportPublicKey(pair.publicKey),
                protected: .init(v: ProtectedEnvelope.version, message: Data(noise.helloMessage).base64EncodedString())
            )
            helloText = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)
        } catch {
            failProtectedHandshake("Could not start protected relay handshake")
            return
        }
        state = .handshaking
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
        base.send(.text(helloText))
    }

    private func handleBaseFrame(_ frame: TransportFrame) {
        switch state {
        case .handshaking:
            guard case .text(let text) = frame, Self.handshakeType(text) == "e2ee_ready" else { return }
            handleReady(text)
        case .open:
            handleOpenFrame(frame)
        case .idle, .closed:
            return
        }
    }

    private func handleReady(_ text: String) {
        guard let ready = try? JSONDecoder().decode(ReadyMessage.self, from: Data(text.utf8)) else {
            failProtectedHandshake("Malformed relay handshake response")
            return
        }
        if let envelope = ready.protectedEnvelope {
            guard envelope.v == ProtectedEnvelope.version else {
                failProtectedHandshake("Unsupported protected relay handshake version")
                return
            }
            let encoded = envelope.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let response = ConnectionOffer.decodeBase64URL(encoded), !response.isEmpty, let noise else {
                failProtectedHandshake("Malformed protected relay handshake response")
                return
            }
            do {
                protectedCodec = try noise.complete(Array(response))
            } catch {
                failProtectedHandshake("Could not authenticate protected relay handshake")
                return
            }
            sharedKey = nil
            minimumMode = .protected
            securityMode = .protected
        } else {
            guard minimumMode != .protected else {
                failProtectedHandshake("Daemon offered only legacy endpoint security")
                return
            }
            binaryCiphertext = ready.binaryCiphertext
            securityMode = .legacy
        }
        noise = nil
        helloText = ""
        retryTask?.cancel()
        retryTask = nil
        state = .open
        onOpen?()
        let pending = pendingSends
        pendingSends = []
        for item in pending where state == .open { send(item) }
    }

    private func handleOpenFrame(_ frame: TransportFrame) {
        // Retries can leave duplicate hello/ready frames in flight at open.
        if case .text(let text) = frame,
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
           let type = Self.handshakeType(text),
           type == "e2ee_hello" || type == "e2ee_ready" {
            return
        }
        if let protectedCodec {
            do {
                onFrame?(try protectedCodec.open(frame))
            } catch {
                failProtectedRecord("Invalid protected relay record")
            }
            return
        }
        guard let sharedKey else { return }
        let cipher: [UInt8]
        let wasBinary: Bool
        switch frame {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
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
        clearConnection()
        guard !closeForwarded else { return }
        closeForwarded = true
        onClose?(close)
    }

    private func clearConnection() {
        retryTask?.cancel()
        retryTask = nil
        state = .closed
        sharedKey = nil
        noise = nil
        protectedCodec = nil
        helloText = ""
        pendingSends = []
    }

    /// Forward local channel failures immediately.
    /// `URLSessionWebSocketTransport` never calls `onClose` for a close it initiated
    /// itself, so without this the owner would not learn of the disconnect until the
    /// next liveness timeout.
    private func fail(_ message: String, code: Int = E2EEChannel.fatalCloseCode) {
        localCloseReason = message
        clearConnection()
        onError?(message)
        base.close(code: code, reason: message)
        handleBaseClose(TransportClose(code: code, reason: message))
    }

    private func failProtectedHandshake(_ message: String) {
        securityFailureReason = message
        fail(message, code: Self.protectedHandshakeFailedCloseCode)
    }

    private func failProtectedRecord(_ message: String) {
        // Discard desynchronized record state, then reconnect with a fresh
        // handshake. The authenticated daemon key remains pinned to protected.
        fail(message, code: Self.protectedRecordFailedCloseCode)
    }

    private static func handshakeType(_ text: String) -> String? {
        try? JSONDecoder().decode(HandshakeType.self, from: Data(text.utf8)).type
    }
}
