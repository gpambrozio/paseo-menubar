import CryptoKit
import Foundation

struct NoiseProtocolError: MessageError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A single Noise direction. ChaChaPoly uses four zero bytes followed by
/// Noise's little-endian 64-bit counter. The all-ones counter is reserved.
struct NoiseCipherState {
    static let maxMessageBytes = Int(UInt16.max)
    static let tagBytes = 16

    private let key: SymmetricKey
    private var counter: UInt64

    init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    mutating func seal(_ plaintext: [UInt8], authenticating ad: Data = Data()) throws -> [UInt8] {
        guard plaintext.count <= Self.maxMessageBytes - Self.tagBytes else {
            throw NoiseProtocolError("Noise plaintext too large")
        }
        let nonce = try nextNonce()
        counter += 1
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad)
        return Array(sealed.ciphertext) + sealed.tag
    }

    mutating func open(_ ciphertext: ArraySlice<UInt8>, authenticating ad: Data = Data()) throws -> [UInt8] {
        guard (Self.tagBytes...Self.maxMessageBytes).contains(ciphertext.count) else {
            throw NoiseProtocolError("Invalid Noise ciphertext length")
        }
        let nonce = try nextNonce()
        let plaintext: Data
        do {
            // CryptoKit's combined representation includes the nonce. Noise
            // carries only the ciphertext and tag, with the nonce implicit.
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: ciphertext.dropLast(Self.tagBytes), tag: ciphertext.suffix(Self.tagBytes)
            )
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseProtocolError("Noise authentication failed")
        }
        counter += 1
        return Array(plaintext)
    }

    private func nextNonce() throws -> ChaChaPoly.Nonce {
        guard counter != UInt64.max else { throw NoiseProtocolError("Noise nonce exhausted") }
        let bytes = withUnsafeBytes(of: counter.littleEndian) { Data($0) }
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + bytes)
    }
}
