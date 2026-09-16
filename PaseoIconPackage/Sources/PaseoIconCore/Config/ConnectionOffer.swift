import Foundation

/// A relay pairing offer, exactly as `paseo daemon pair` issues it and the
/// Paseo app stores it. `v` is pinned to 2: that is the only shape the 0.4.0
/// protocol defines, and an offer of another version is rejected rather than
/// guessed at.
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

    public init(serverId: String, daemonPublicKeyB64: String, relay: Relay) {
        self.v = 2
        self.serverId = serverId
        self.daemonPublicKeyB64 = daemonPublicKeyB64
        self.relay = relay
    }
}

public enum ConnectionOfferError: Error, Equatable {
    case missingFragment
    case invalidBase64
    case invalidJSON(String)
    case unsupportedVersion(Int)
    case emptyField(String)
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
        } catch {
            throw ConnectionOfferError.invalidJSON(String(describing: error))
        }
        return try offer.validated()
    }

    /// The offer's own invariants: version 2 and no empty identifiers. Applied
    /// to parsed offers and to offers assembled from the registry alike.
    public func validated() throws -> ConnectionOffer {
        guard v == 2 else { throw ConnectionOfferError.unsupportedVersion(v) }
        guard !serverId.isEmpty else { throw ConnectionOfferError.emptyField("serverId") }
        guard !daemonPublicKeyB64.isEmpty else { throw ConnectionOfferError.emptyField("daemonPublicKeyB64") }
        guard !relay.endpoint.isEmpty else { throw ConnectionOfferError.emptyField("relay.endpoint") }
        return self
    }

    static func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
