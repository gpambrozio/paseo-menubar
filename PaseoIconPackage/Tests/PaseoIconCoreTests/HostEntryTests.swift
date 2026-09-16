import Testing
@testable import PaseoIconCore

struct HostEntryTests {
    private let offer = ConnectionOffer(serverId: "srv-1", daemonPublicKeyB64: "k", relay: .init(endpoint: "relay.paseo.sh:443"))

    @Test("exposes id and label for both shapes")
    func idAndLabel() {
        let direct = HostEntry.directTcp(id: "d", label: "Desk", endpoint: "127.0.0.1:6767", useTls: false, password: nil)
        let relay = HostEntry.relay(id: "r", label: nil, offer: offer)
        #expect(direct.id == "d")
        #expect(direct.label == "Desk")
        #expect(relay.id == "r")
        #expect(relay.label == nil)
    }

    @Test("the endpoint hint is the address the entry dials")
    func endpointHint() {
        let direct = HostEntry.directTcp(id: "d", label: nil, endpoint: "127.0.0.1:6767", useTls: false, password: nil)
        let relay = HostEntry.relay(id: "r", label: nil, offer: offer)
        #expect(direct.endpointHint == "127.0.0.1:6767")
        #expect(relay.endpointHint == "relay.paseo.sh:443")
    }
}
