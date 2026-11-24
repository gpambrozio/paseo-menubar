import CryptoKit
import Foundation

/// Monotonic protected-mode pins, keyed by the decoded daemon public key.
/// The app injects its preferences. An omitted preferences store is in-memory.
@MainActor
public final class RelaySecurityPinStore {
    static let defaultsKey = "relayProtectedDaemonPins"

    private let persist: ([String]) -> Void
    private var identities: Set<String>

    public convenience init(defaults: UserDefaults? = nil) {
        self.init(persistedIdentities: defaults?.stringArray(forKey: Self.defaultsKey) ?? []) {
            defaults?.set($0, forKey: Self.defaultsKey)
        }
    }

    init(persistedIdentities: [String], persist: @escaping ([String]) -> Void) {
        identities = Set(persistedIdentities)
        self.persist = persist
    }

    func minimumMode(for identity: String, advertised: RelaySecurityMode?) -> RelaySecurityMode? {
        if advertised == .protected {
            pin(identity)
        }
        return identities.contains(identity) ? .protected : advertised
    }

    func pin(_ identity: String) {
        guard identities.insert(identity).inserted else { return }
        persist(identities.sorted())
    }

    nonisolated static func identity(publicKeyB64: String) throws -> String {
        let key = try E2EEBox.importPublicKey(base64: publicKeyB64)
        return Data(SHA256.hash(data: key)).base64EncodedString()
    }
}
