import CryptoKit
import Foundation

/// The host set the fleet is built from. Only the registry session builds
/// one, and only through `validate`, which is what makes the fleet's
/// duplicate-id invariant hold.
public struct AppConfig: Equatable, Sendable {
    public let version = 1
    public let hosts: [HostEntry]

    public let fallbackHosts: [String: [HostEntry]]

    public var fingerprint: String {
        fingerprintDigest(ConfigFingerprintInput(
            hosts: hosts.sorted { $0.id < $1.id },
            fallbackHosts: fallbackHosts
        ))
    }

    /// Duplicate ids and invalid offers are rejected with a message per issue.
    public static func validate(
        hosts: [HostEntry], fallbackHosts: [String: [HostEntry]] = [:]
    ) throws -> AppConfig {
        var issues: [String] = []
        var primaries: [String: HostEntry] = [:]
        for entry in hosts {
            if primaries[entry.id] != nil {
                issues.append("Duplicate host id \"\(entry.id)\". Each host needs its own id.")
            } else {
                primaries[entry.id] = entry
            }
            validateEntry(entry, issues: &issues)
        }

        for id in fallbackHosts.keys.sorted() {
            guard let routes = fallbackHosts[id] else { continue }
            guard let primary = primaries[id] else {
                issues.append("Host \(id): fallback routes require a primary host.")
                continue
            }
            for route in routes {
                validateEntry(route, issues: &issues)
                guard route.id == id else {
                    issues.append("Host \(id): a fallback route must use its primary host's id.")
                    continue
                }
                guard case .relay(_, _, let primaryOffer, _) = primary,
                      case .relay(_, _, let offer, _) = route,
                      primaryOffer.serverId == offer.serverId,
                      let identity = try? RelaySecurityPinStore.identity(publicKeyB64: offer.daemonPublicKeyB64),
                      identity == (try? RelaySecurityPinStore.identity(publicKeyB64: primaryOffer.daemonPublicKeyB64)) else {
                    issues.append("Host \(id): a fallback must be a relay route for the same daemon.")
                    continue
                }
                if primaryOffer.minimumSecurityMode != offer.minimumSecurityMode {
                    issues.append("Host \(id): all relay routes must share the same minimum security mode.")
                }
                do {
                    _ = try offer.relayWebSocketURL()
                } catch {
                    issues.append("Host \(id): invalid fallback relay endpoint.")
                }
            }
        }
        guard issues.isEmpty else { throw AppConfigError(issues: issues) }
        return AppConfig(hosts: hosts, fallbackHosts: fallbackHosts.filter { !$0.value.isEmpty })
    }

    private static func validateEntry(_ entry: HostEntry, issues: inout [String]) {
        if let label = entry.label, label.isEmpty {
            issues.append("Host \(entry.id): label must not be empty when present.")
        }
        if case .relay(_, _, let offer, _) = entry {
            do {
                _ = try offer.validated()
            } catch {
                issues.append("Host \(entry.id): \(errorText(error))")
            }
        }
    }

    /// A config that skipped validation. Nothing in the app builds one this
    /// way: the fleet's duplicate-id guard is the last line of defence for a
    /// call site that does, and this is how that guard is tested.
    public static func unvalidated(hosts: [HostEntry]) -> AppConfig {
        AppConfig(hosts: hosts, fallbackHosts: [:])
    }

    private init(hosts: [HostEntry], fallbackHosts: [String: [HostEntry]]) {
        self.hosts = hosts
        self.fallbackHosts = fallbackHosts
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
        case .invalidJSON: "the offer is not valid JSON"
        case .unsupportedVersion(let version): "unsupported offer version \(version)"
        case .unsupportedMinimumSecurityMode: "minimumSecurityMode must be protected when present"
        case .emptyField(let field): "\(field) must not be empty"
        case .invalidDaemonPublicKey: "daemonPublicKeyB64 is not a 32-byte base64 key"
        }
    }
}

private let fingerprintKey = SymmetricKey(size: .bits256)

/// Stable within this process, used to tell a real change in the Paseo
/// app's registry apart from Chromium rewriting its database for keys the
/// tray does not care about. Ids are unique, so sorting by id is a total
/// order. The keyed digest keeps the serialized credentials out of the fingerprint.
public func hostsFingerprint(_ hosts: [HostEntry]) -> String {
    fingerprintDigest(hosts.sorted { $0.id < $1.id })
}

private struct ConfigFingerprintInput: Encodable {
    let hosts: [HostEntry]
    let fallbackHosts: [String: [HostEntry]]
}

private func fingerprintDigest(_ input: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(input) else { return "" }
    return Data(HMAC<SHA256>.authenticationCode(for: data, using: fingerprintKey)).base64EncodedString()
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
        case .relay(_, _, let offer, let password):
            try container.encode("relay", forKey: .type)
            try container.encode(offer, forKey: .offer)
            try container.encodeIfPresent(password, forKey: .password)
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
            self = .relay(
                id: id,
                label: label,
                offer: try container.decode(ConnectionOffer.self, forKey: .offer),
                password: try container.decodeIfPresent(String.self, forKey: .password)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown host type \(other)")
        }
    }
}
