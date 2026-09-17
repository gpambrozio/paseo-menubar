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
    case keyGenerationFailed
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

    public static func generateKeyPair() throws -> E2EEKeyPair {
        // libsodium's keypair generation only fails before sodium_init, which
        // Sodium() performs, so this is unreachable — but "no force unwraps" has
        // no exceptions, and the caller already has a failure path for key
        // derivation two lines further on. A nil here would otherwise be a dead
        // menu bar rather than a named error.
        guard let pair = Sodium().box.keyPair() else { throw E2EEBoxError.keyGenerationFailed }
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
