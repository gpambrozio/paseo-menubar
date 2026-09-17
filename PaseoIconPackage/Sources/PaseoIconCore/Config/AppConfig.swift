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
        case .invalidDaemonPublicKey: "daemonPublicKeyB64 is not a 32-byte base64 key"
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
