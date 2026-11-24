import Foundation

/// A relay pairing offer, exactly as `paseo daemon pair` issues it and the
/// Paseo app stores it. Version 2 also carries an optional protected floor.
public struct ConnectionOffer: Codable, Equatable, Sendable {
    public struct Relay: Codable, Equatable, Sendable {
        public var endpoint: String
        public var useTls: Bool?

        public init(endpoint: String, useTls: Bool? = nil) {
            self.endpoint = endpoint
            self.useTls = useTls
        }
    }

    public var v: Int
    public var serverId: String
    public var daemonPublicKeyB64: String
    public var relay: Relay
    public var minimumSecurityMode: RelaySecurityMode?

    public init(
        serverId: String,
        daemonPublicKeyB64: String,
        relay: Relay,
        minimumSecurityMode: RelaySecurityMode? = nil
    ) {
        self.v = 2
        self.serverId = serverId
        self.daemonPublicKeyB64 = daemonPublicKeyB64
        self.relay = relay
        self.minimumSecurityMode = minimumSecurityMode
    }

    private enum CodingKeys: String, CodingKey {
        case v, serverId, daemonPublicKeyB64, relay, minimumSecurityMode
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        v = try fields.decode(Int.self, forKey: .v)
        serverId = try fields.decode(String.self, forKey: .serverId)
        daemonPublicKeyB64 = try fields.decode(String.self, forKey: .daemonPublicKeyB64)
        relay = try fields.decode(Relay.self, forKey: .relay)
        if fields.contains(.minimumSecurityMode) {
            guard (try? fields.decode(String.self, forKey: .minimumSecurityMode)) == "protected" else {
                throw ConnectionOfferError.unsupportedMinimumSecurityMode
            }
            minimumSecurityMode = .protected
        }
    }
}

public enum ConnectionOfferError: Error, Equatable {
    case missingFragment
    case invalidBase64
    case invalidJSON
    case unsupportedVersion(Int)
    case unsupportedMinimumSecurityMode
    case emptyField(String)
    case invalidDaemonPublicKey
}

extension ConnectionOffer {
    static let fragmentPrefix = "#offer="

    /// Parses the URL `paseo daemon pair` prints. The offer rides in the URL
    /// fragment as base64url JSON; anything before `#offer=` is ignored, so a
    /// bare fragment and a full `paseo://` or `https://` URL both parse.
    public static func parse(fromURL input: String) throws -> ConnectionOffer {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: fragmentPrefix) else {
            throw ConnectionOfferError.missingFragment
        }
        let encoded = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { throw ConnectionOfferError.missingFragment }
        guard let data = decodeBase64URL(encoded) else { throw ConnectionOfferError.invalidBase64 }
        let offer: ConnectionOffer
        do {
            offer = try JSONDecoder().decode(ConnectionOffer.self, from: data)
        } catch let error as ConnectionOfferError {
            throw error
        } catch {
            throw ConnectionOfferError.invalidJSON
        }
        return try offer.validated()
    }

    /// The offer's own invariants: version 2 and no empty identifiers. Applied
    /// to parsed offers and to offers assembled from the registry alike.
    public func validated() throws -> ConnectionOffer {
        guard v == 2 else { throw ConnectionOfferError.unsupportedVersion(v) }
        guard minimumSecurityMode == nil || minimumSecurityMode == .protected else {
            throw ConnectionOfferError.unsupportedMinimumSecurityMode
        }
        guard !serverId.isEmpty else { throw ConnectionOfferError.emptyField("serverId") }
        guard !daemonPublicKeyB64.isEmpty else { throw ConnectionOfferError.emptyField("daemonPublicKeyB64") }
        // Decoded here, not merely checked for emptiness. A key that is
        // base64url rather than base64, or that decodes to the wrong length,
        // used to get all the way to `E2EEChannel.init` — which fails
        // correctly, but reports `.disconnected(reason:)`, and
        // `HostConnection.handleStatus` drops a reason that is not an auth
        // rejection. The host then reads as merely offline, retry rebuilds into
        // the same dead end, and nothing ever names the cause. Validating it
        // here makes it a named entry failure instead.
        do {
            _ = try E2EEBox.importPublicKey(base64: daemonPublicKeyB64)
        } catch {
            throw ConnectionOfferError.invalidDaemonPublicKey
        }
        guard !relay.endpoint.isEmpty else { throw ConnectionOfferError.emptyField("relay.endpoint") }
        return self
    }

    func relayWebSocketURL() throws -> URL {
        let useTls = relay.useTls ?? DaemonEndpoints.shouldUseTlsForDefaultHostedRelay(relay.endpoint)
        return try DaemonEndpoints.relayWebSocketURL(endpoint: relay.endpoint, useTls: useTls, serverId: serverId)
    }

    static func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
