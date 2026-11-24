import CryptoKit
import Foundation
import Testing
@testable import PaseoIconCore

struct ProtectedRelayCryptoTests {
    private struct Fixture: Decodable {
        struct InvalidReady: Decodable {
            let error: String
            let offeredBinary: Bool
            let ready: String
        }

        let staticPublicKey: String
        let clientEphemeral: String
        let hello: String
        let ready: String
        let clientText: String
        let clientTextWire: String
        let clientEmptyWire: String
        let clientMultichunkBytes: Int
        let clientMultichunkWireBytes: Int
        let clientMultichunkSHA256: String
        let serverText: String
        let serverTextWire: String
        let serverBinary: String
        let serverBinaryWire: String
        let serverEmptyWire: String
        let readyWithoutBinary: String
        let fallbackBinaryWire: String
        let invalidReady: [InvalidReady]
        let counterKey: String
        let highCounterCiphertext: String

        static func load() throws -> Self {
            let url = try #require(Bundle.module.url(
                forResource: "protected-relay-vectors", withExtension: "json", subdirectory: "Fixtures"
            ))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }

        func initiator(offeredBinary: Bool = true) throws -> NoiseNKInitiator {
            try NoiseNKInitiator(
                remoteStatic: ProtectedRelayCryptoTests.bytes(staticPublicKey),
                binaryCiphertext: offeredBinary,
                testEphemeral: ProtectedRelayCryptoTests.bytes(clientEphemeral)
            )
        }
    }

    private static func bytes(_ base64: String) throws -> [UInt8] {
        Array(try #require(Data(base64Encoded: base64)))
    }

    @Test("Matches the upstream handshake and both record directions")
    func upstreamInterop() throws {
        let fixture = try Fixture.load()
        let initiator = try fixture.initiator()
        #expect(initiator.helloMessage == (try Self.bytes(fixture.hello)))
        let codec = try initiator.complete(Self.bytes(fixture.ready))
        #expect(codec.binaryCiphertext)
        #expect(throws: NoiseProtocolError("Noise handshake already completed")) {
            try initiator.complete(Self.bytes(fixture.ready))
        }

        #expect(try codec.seal(.binary([])) == .binary(Self.bytes(fixture.clientEmptyWire)))
        #expect(try codec.seal(.text(fixture.clientText)) == .text(fixture.clientTextWire))
        let payload = (0..<fixture.clientMultichunkBytes).map { UInt8($0 % 251) }
        let sealed = try codec.seal(.binary(payload))
        guard case .binary(let bytes) = sealed else {
            Issue.record("Expected binary wire frame")
            return
        }
        #expect(bytes.count == fixture.clientMultichunkWireBytes)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == fixture.clientMultichunkSHA256)

        #expect(try codec.open(.text(fixture.serverTextWire)) == .text(fixture.serverText))
        #expect(try codec.open(.binary(Self.bytes(fixture.serverBinaryWire))) == .binary(Self.bytes(fixture.serverBinary)))
        #expect(try codec.open(.text(fixture.serverEmptyWire)) == .text(""))
    }

    @Test("Uses base64 for a binary frame when the authenticated selection disables binary wire frames")
    func binaryPreference() throws {
        let fixture = try Fixture.load()
        let codec = try fixture.initiator().complete(Self.bytes(fixture.readyWithoutBinary))
        #expect(!codec.binaryCiphertext)
        #expect(try codec.seal(.binary(Self.bytes(fixture.serverBinary))) == .text(fixture.fallbackBinaryWire))
    }

    @Test("Rejects authenticated but invalid parameters and unauthenticated responses")
    func handshakeRejections() throws {
        let fixture = try Fixture.load()
        for invalid in fixture.invalidReady {
            let client = try fixture.initiator(offeredBinary: invalid.offeredBinary)
            #expect(throws: NoiseProtocolError(invalid.error)) { try client.complete(Self.bytes(invalid.ready)) }
        }

        let client = try fixture.initiator()
        let ready = try Self.bytes(fixture.ready)
        var tampered = ready
        tampered[tampered.count - 1] ^= 1
        #expect(throws: NoiseProtocolError("Noise authentication failed")) { try client.complete(tampered) }
        #expect(throws: NoiseProtocolError("Noise handshake already completed")) { try client.complete(ready) }
        #expect(throws: NoiseProtocolError("Invalid Noise response length")) {
            try fixture.initiator().complete(Array(ready.prefix(47)))
        }
        #expect(throws: NoiseProtocolError("Invalid Noise response length")) {
            try fixture.initiator().complete([UInt8](repeating: 0, count: 65536))
        }
        let lowOrderKey = [UInt8](repeating: 0, count: 32)
        #expect(throws: NoiseProtocolError("Invalid Noise DH public key")) {
            try NoiseNKInitiator(remoteStatic: lowOrderKey)
        }
        #expect(throws: NoiseProtocolError("Invalid Noise DH public key")) {
            try fixture.initiator().complete(lowOrderKey + ready.dropFirst(32))
        }
    }

    @Test("Replay, reflection, tampering and reordered traffic cannot advance the receive nonce")
    func recordAuthentication() throws {
        let fixture = try Fixture.load()
        let codec = try fixture.initiator().complete(Self.bytes(fixture.ready))
        let first = TransportFrame.text(fixture.serverTextWire)
        let second = TransportFrame.binary(try Self.bytes(fixture.serverBinaryWire))
        var tampered = try Self.bytes(fixture.serverTextWire)
        tampered[tampered.count - 1] ^= 1

        #expect(throws: NoiseProtocolError("Noise authentication failed")) { try codec.open(second) }
        #expect(throws: NoiseProtocolError("Noise authentication failed")) { try codec.open(.binary(tampered)) }
        let reflected = try codec.seal(.text("client message"))
        #expect(throws: NoiseProtocolError("Noise authentication failed")) { try codec.open(reflected) }
        #expect(try codec.open(first) == .text(fixture.serverText))
        #expect(throws: NoiseProtocolError("Noise authentication failed")) { try codec.open(first) }
        #expect(try codec.open(second) == .binary(Self.bytes(fixture.serverBinary)))
    }

    @Test("Matches upstream nonce byte order and refuses to use the reserved all-ones nonce")
    func counterLimit() throws {
        let fixture = try Fixture.load()
        let key = SymmetricKey(data: try Self.bytes(fixture.counterKey))
        var highCounter = NoiseCipherState(key: key, counter: 0x0102030405060708)
        #expect(try highCounter.seal([1, 2, 3]) == Self.bytes(fixture.highCounterCiphertext))

        var sender = NoiseCipherState(key: key, counter: UInt64.max - 1)
        var receiver = NoiseCipherState(key: key, counter: UInt64.max - 1)
        let last = try sender.seal([7])
        #expect(try receiver.open(last[...]) == [7])
        #expect(throws: NoiseProtocolError("Noise nonce exhausted")) { try sender.seal([7]) }
        #expect(throws: NoiseProtocolError("Noise nonce exhausted")) { try receiver.open(last[...]) }
    }

    private static let testKey = SymmetricKey(data: [UInt8](repeating: 23, count: 32))

    private func freshCodec() -> ProtectedRecordCodec {
        ProtectedRecordCodec(
            sender: NoiseCipherState(key: Self.testKey),
            receiver: NoiseCipherState(key: Self.testKey),
            binaryCiphertext: true
        )
    }

    @Test("Decodes exact-boundary and multi-chunk records, and refuses split or merged records")
    func chunkBoundaries() throws {
        let sender = freshCodec()
        let receiver = freshCodec()
        for count in [65513, 65514, 2 * 65513] {
            let frame = TransportFrame.binary([UInt8](repeating: 0x9e, count: count))
            #expect(try receiver.open(sender.seal(frame)) == frame)
        }

        let large = TransportFrame.binary([UInt8](repeating: 9, count: 65514))
        guard case .binary(let wire) = try freshCodec().seal(large) else {
            Issue.record("Expected binary wire frame")
            return
        }
        #expect(throws: NoiseProtocolError("Protected record length mismatch")) {
            try freshCodec().open(.binary(Array(wire.prefix(65537))))
        }
        #expect(throws: NoiseProtocolError("Protected record length mismatch")) {
            try freshCodec().open(.binary(wire + wire))
        }
    }

    private func wrapChunk(_ plaintext: [UInt8]) throws -> TransportFrame {
        var sender = NoiseCipherState(key: Self.testKey)
        let chunk = try sender.seal(plaintext)
        return .binary([UInt8(chunk.count >> 8), UInt8(truncatingIfNeeded: chunk.count)] + chunk)
    }

    @Test("Validates prefix bounds, authenticated framing and strict text encoding")
    func malformedRecords() throws {
        for invalid in [[UInt8](), [0], [0, 21], [255, 255, 0]] {
            #expect(throws: NoiseProtocolError.self) { try freshCodec().open(.binary(invalid)) }
        }

        let invalidHeaders: [([UInt8], String)] = [
            ([1, 3, 255, 255, 255, 255], "Protected record length mismatch"),
            ([2, 3, 0, 0, 0, 0], "Invalid protected frame kind"),
            ([1, 7, 0, 0, 0, 0], "Reserved protected chunk flag set"),
            ([1, 2, 0, 0, 0, 0], "Incorrect protected chunk flags"),
            ([1, 1, 0, 0, 0, 0], "Incorrect protected chunk flags"),
            ([0, 3, 0, 0, 0, 1, 255], "Invalid protected record UTF-8"),
        ]
        for (plaintext, error) in invalidHeaders {
            let wire = try wrapChunk(plaintext)
            #expect(throws: NoiseProtocolError(error)) { try freshCodec().open(wire) }
        }

        let bom = try wrapChunk([0, 3, 0, 0, 0, 4, 0xef, 0xbb, 0xbf, 0x61])
        #expect(try freshCodec().open(bom) == .text("a"))
    }
}
