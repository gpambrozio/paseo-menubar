import CryptoKit
import Foundation

public enum RelaySecurityMode: String, Codable, Sendable {
    case legacy
    case protected
}

/// Initiator of Noise_NK_25519_ChaChaPoly_SHA256 with Paseo's authenticated
/// parameters. One instance belongs to one relay connection attempt.
final class NoiseNKInitiator {
    private static let keyBytes = 32
    private static let parameterVersion: UInt8 = 1
    private static let binaryFlag: UInt8 = 1
    private static let prologue = Data("paseo-relay-e2ee/1".utf8)

    let helloMessage: [UInt8]

    private struct PendingHandshake {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let offeredBinary: Bool
        var symmetric: NoiseSymmetricState
    }

    private var pending: PendingHandshake?

    convenience init(remoteStatic: [UInt8], binaryCiphertext: Bool = true) throws {
        try self.init(
            remoteStatic: remoteStatic,
            binaryCiphertext: binaryCiphertext,
            ephemeral: Curve25519.KeyAgreement.PrivateKey()
        )
    }

    /// Deterministic ephemeral injection for the upstream interoperability tests.
    convenience init(remoteStatic: [UInt8], binaryCiphertext: Bool = true, testEphemeral: [UInt8]) throws {
        try self.init(
            remoteStatic: remoteStatic,
            binaryCiphertext: binaryCiphertext,
            ephemeral: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: testEphemeral)
        )
    }

    private init(
        remoteStatic: [UInt8], binaryCiphertext: Bool, ephemeral: Curve25519.KeyAgreement.PrivateKey
    ) throws {
        guard remoteStatic.count == Self.keyBytes else {
            throw NoiseProtocolError("Invalid Noise public key length")
        }
        let localPublicKey = ephemeral.publicKey.rawRepresentation
        var symmetric = NoiseSymmetricState()
        symmetric.mixHash(Self.prologue)
        // NK pre-message: <- s
        symmetric.mixHash(Data(remoteStatic))
        // NK message 1: -> e, es
        symmetric.mixHash(localPublicKey)
        var cipher = symmetric.mixKey(try Self.sharedSecret(ephemeral, remoteStatic[...]))
        let offered = [Self.parameterVersion, binaryCiphertext ? Self.binaryFlag : 0]
        let payload = try cipher.seal(offered, authenticating: symmetric.hash)
        symmetric.mixHash(Data(payload))
        helloMessage = Array(localPublicKey) + payload
        pending = PendingHandshake(ephemeral: ephemeral, offeredBinary: binaryCiphertext, symmetric: symmetric)
    }

    func complete(_ response: [UInt8]) throws -> ProtectedRecordCodec {
        guard var handshake = pending else { throw NoiseProtocolError("Noise handshake already completed") }
        // A ready consumes the handshake even if authentication or validation fails.
        pending = nil
        guard (Self.keyBytes + NoiseCipherState.tagBytes...NoiseCipherState.maxMessageBytes).contains(response.count) else {
            throw NoiseProtocolError("Invalid Noise response length")
        }

        // NK message 2: <- e, ee
        let remoteEphemeral = response.prefix(Self.keyBytes)
        handshake.symmetric.mixHash(Data(remoteEphemeral))
        var cipher = handshake.symmetric.mixKey(try Self.sharedSecret(handshake.ephemeral, remoteEphemeral))
        let ciphertext = response.dropFirst(Self.keyBytes)
        let selected = try cipher.open(ciphertext, authenticating: handshake.symmetric.hash)
        handshake.symmetric.mixHash(Data(ciphertext))

        guard selected.count == 2 else { throw NoiseProtocolError("Invalid protected parameter payload") }
        guard selected[0] == Self.parameterVersion else {
            throw NoiseProtocolError("Unsupported protected parameter version")
        }
        guard selected[1] & ~Self.binaryFlag == 0 else {
            throw NoiseProtocolError("Reserved protected parameter flag set")
        }
        let binaryCiphertext = selected[1] & Self.binaryFlag != 0
        guard !binaryCiphertext || handshake.offeredBinary else {
            throw NoiseProtocolError("Daemon selected an unoffered protected parameter")
        }

        let (send, receive) = handshake.symmetric.split()
        return ProtectedRecordCodec(sender: send, receiver: receive, binaryCiphertext: binaryCiphertext)
    }

    private static func sharedSecret(
        _ local: Curve25519.KeyAgreement.PrivateKey, _ remote: ArraySlice<UInt8>
    ) throws -> Data {
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
            let secret = try local.sharedSecretFromKeyAgreement(with: publicKey)
            return try secret.withUnsafeBytes { bytes in
                guard bytes.reduce(UInt8(0), |) != 0 else {
                    throw NoiseProtocolError("Invalid Noise DH public key")
                }
                return Data(bytes)
            }
        } catch {
            throw NoiseProtocolError("Invalid Noise DH public key")
        }
    }
}

private struct NoiseSymmetricState {
    // This protocol name is exactly SHA256's 32-byte hash length, so Noise
    // initializes h and ck to the name itself without padding or hashing.
    private static let protocolName = Data("Noise_NK_25519_ChaChaPoly_SHA256".utf8)
    private var chainingKey = SymmetricKey(data: protocolName)
    private(set) var hash = protocolName

    mutating func mixHash(_ bytes: Data) {
        hash = Data(SHA256.hash(data: hash + bytes))
    }

    mutating func mixKey(_ secret: Data) -> NoiseCipherState {
        let (nextChainingKey, cipherKey) = deriveKeys(secret)
        chainingKey = nextChainingKey
        return NoiseCipherState(key: cipherKey)
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (first, second) = deriveKeys(Data())
        return (NoiseCipherState(key: first), NoiseCipherState(key: second))
    }

    // Noise HKDF with two outputs. The first output is also input to the second HMAC.
    private func deriveKeys(_ input: Data) -> (SymmetricKey, SymmetricKey) {
        let extracted = HMAC<SHA256>.authenticationCode(for: input, using: chainingKey)
        let tempKey = SymmetricKey(data: Data(extracted))
        let first = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: tempKey))
        let second = Data(HMAC<SHA256>.authenticationCode(for: first + Data([2]), using: tempKey))
        return (SymmetricKey(data: first), SymmetricKey(data: second))
    }
}
