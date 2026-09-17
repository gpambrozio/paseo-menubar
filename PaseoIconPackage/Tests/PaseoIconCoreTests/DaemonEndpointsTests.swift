import Foundation
import Testing
@testable import PaseoIconCore

struct DaemonEndpointsTests {
    @Test("parses host:port")
    func hostPort() throws {
        let parsed = try DaemonEndpoints.parseHostPort("localhost:6767")
        #expect(parsed == HostPort(host: "localhost", port: 6767, isIPv6: false))
    }

    @Test("parses a bracketed IPv6 host")
    func ipv6() throws {
        let parsed = try DaemonEndpoints.parseHostPort("[::1]:6767")
        #expect(parsed == HostPort(host: "::1", port: 6767, isIPv6: true))
    }

    @Test("rejects a missing port and an out-of-range port")
    func badPorts() {
        #expect(throws: DaemonEndpointError.self) { try DaemonEndpoints.parseHostPort("localhost") }
        #expect(throws: DaemonEndpointError.invalidPort("70000")) { try DaemonEndpoints.parseHostPort("localhost:70000") }
        #expect(throws: DaemonEndpointError.hostRequired) { try DaemonEndpoints.parseHostPort("  ") }
    }

    @Test("builds the direct daemon URL at /ws")
    func daemonURL() throws {
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "127.0.0.1:6767", useTls: false).absoluteString == "ws://127.0.0.1:6767/ws")
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "host.example:443", useTls: true).absoluteString == "wss://host.example:443/ws")
        #expect(try DaemonEndpoints.daemonWebSocketURL(endpoint: "[::1]:6767", useTls: false).absoluteString == "ws://[::1]:6767/ws")
    }

    @Test("builds the relay client URL with serverId, role, and v=2")
    func relayURL() throws {
        let url = try DaemonEndpoints.relayWebSocketURL(endpoint: "relay.paseo.sh:443", useTls: true, serverId: "srv 1")
        #expect(url.absoluteString == "wss://relay.paseo.sh:443/ws?serverId=srv%201&role=client&v=2")
    }

    @Test("the hosted relay default is TLS on 443 only")
    func hostedRelayTls() {
        #expect(DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("relay.paseo.sh:443"))
        #expect(!DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("127.0.0.1:8787"))
        #expect(!DaemonEndpoints.shouldUseTlsForDefaultHostedRelay("garbage"))
    }
}
