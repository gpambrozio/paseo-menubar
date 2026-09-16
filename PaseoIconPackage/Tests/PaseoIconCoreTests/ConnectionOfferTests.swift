import Foundation
import Testing
@testable import PaseoIconCore

struct ConnectionOfferTests {
    private static let offerJSON = #"{"v":2,"serverId":"srv-1","daemonPublicKeyB64":"AAAA","relay":{"endpoint":"relay.paseo.sh:443"}}"#

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("parses the fragment of a pairing URL")
    func parsesFragment() throws {
        let url = "paseo://pair#offer=\(Self.base64URL(Self.offerJSON))"
        let offer = try ConnectionOffer.parse(fromURL: url)
        #expect(offer.serverId == "srv-1")
        #expect(offer.daemonPublicKeyB64 == "AAAA")
        #expect(offer.relay.endpoint == "relay.paseo.sh:443")
        #expect(offer.relay.useTls == nil)
    }

    @Test("accepts a bare fragment and surrounding whitespace")
    func bareFragment() throws {
        let offer = try ConnectionOffer.parse(fromURL: "  #offer=\(Self.base64URL(Self.offerJSON))\n")
        #expect(offer.serverId == "srv-1")
    }

    @Test("rejects input without an offer fragment")
    func missingFragment() {
        #expect(throws: ConnectionOfferError.missingFragment) {
            try ConnectionOffer.parse(fromURL: "https://app.paseo.sh/")
        }
    }

    @Test("rejects an offer version other than 2")
    func wrongVersion() {
        let json = #"{"v":3,"serverId":"s","daemonPublicKeyB64":"k","relay":{"endpoint":"r:443"}}"#
        #expect(throws: ConnectionOfferError.unsupportedVersion(3)) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL(json))")
        }
    }

    @Test("rejects an empty serverId")
    func emptyServerId() {
        let json = #"{"v":2,"serverId":"","daemonPublicKeyB64":"k","relay":{"endpoint":"r:443"}}"#
        #expect(throws: ConnectionOfferError.emptyField("serverId")) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL(json))")
        }
    }

    @Test("rejects base64 that is not JSON")
    func notJSON() {
        #expect(throws: ConnectionOfferError.self) {
            try ConnectionOffer.parse(fromURL: "#offer=\(Self.base64URL("not json"))")
        }
    }
}
