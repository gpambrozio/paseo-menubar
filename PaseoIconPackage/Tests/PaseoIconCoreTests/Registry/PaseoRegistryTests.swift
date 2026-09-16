import Foundation
import Testing
@testable import PaseoIconCore

struct PaseoRegistryTests {
    /// The stored profile shape, with overrides, serialized the way the Paseo
    /// app stores it.
    private func profile(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "serverId": "srv_one",
            "label": "Mac.localdomain",
            "lifecycle": [:],
            "connections": [["id": "direct:localhost:6767", "type": "directTcp", "endpoint": "localhost:6767"]],
            "preferredConnectionId": "direct:localhost:6767",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "updatedAt": "2026-01-01T00:00:00.000Z",
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    private func json(_ profiles: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: profiles), as: UTF8.self)
    }

    @Test("maps a direct TCP host, keying it by serverId")
    func directHost() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile()]))
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.hosts == [.directTcp(id: "srv_one", label: "Mac.localdomain", endpoint: "localhost:6767", useTls: false, password: nil)])
    }

    @Test("rebuilds a relay offer from the stored connection")
    func relayHost() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "serverId": "srv_two",
            "label": "ai-mbp.local",
            "connections": [[
                "id": "relay:wss:relay.paseo.sh:443",
                "type": "relay",
                "relayEndpoint": "relay.paseo.sh:443",
                "useTls": true,
                "daemonPublicKeyB64": "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
            ]],
            "preferredConnectionId": "relay:wss:relay.paseo.sh:443",
        ])]))
        #expect(snapshot.hosts.first == .relay(
            id: "srv_two",
            label: "ai-mbp.local",
            offer: ConnectionOffer(
                serverId: "srv_two",
                daemonPublicKeyB64: "ZLGX9aIvVIojj9KNAeXIaIqGmAeIr7kMKdVvR0cDzXc=",
                relay: .init(endpoint: "relay.paseo.sh:443", useTls: true)
            )
        ))
    }

    @Test("keeps two relay hosts apart even though their connection ids are identical")
    func sharedConnectionId() throws {
        let shared: [String: Any] = [
            "id": "relay:wss:relay.paseo.sh:443",
            "type": "relay",
            "relayEndpoint": "relay.paseo.sh:443",
            "useTls": true,
            "daemonPublicKeyB64": "AAAA",
        ]
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_a", "connections": [shared], "preferredConnectionId": shared["id"] as Any]),
            profile(["serverId": "srv_b", "connections": [shared], "preferredConnectionId": shared["id"] as Any]),
        ]))
        #expect(snapshot.hosts.map(\.id) == ["srv_a", "srv_b"])
    }

    @Test("keeps only the first profile for a repeated serverId and names the loser")
    func duplicateServerId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["label": "Direct one"]),
            profile([
                "label": "Relay twin",
                "connections": [["id": "relay:wss:relay.paseo.sh:443", "type": "relay", "relayEndpoint": "relay.paseo.sh:443", "useTls": true, "daemonPublicKeyB64": "AAAA"]],
                "preferredConnectionId": "relay:wss:relay.paseo.sh:443",
            ]),
        ]))
        // The id keys the fleet's connection map, so admitting both leaves one
        // live socket labelled and typed as the other.
        #expect(snapshot.hosts.count == 1)
        #expect(snapshot.hosts.first?.id == "srv_one")
        #expect(snapshot.hosts.first?.label == "Direct one")
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Relay twin"))
        #expect(try #require(snapshot.failures.first).contains("srv_one"))
    }

    @Test("falls back to a supported connection when the preferred one is not")
    func unsupportedPreference() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [
                ["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"],
                ["id": "direct:1", "type": "directTcp", "endpoint": "10.0.0.9:6767"],
            ],
            "preferredConnectionId": "pipe:1",
        ])]))
        #expect(snapshot.hosts.count == 1)
        if case .directTcp(_, _, let endpoint, _, _) = try #require(snapshot.hosts.first) {
            #expect(endpoint == "10.0.0.9:6767")
        } else {
            Issue.record("expected a direct host")
        }
    }

    @Test("drops a host with no supported connection and names it in failures")
    func noSupportedConnection() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "label": "Pipe only",
            "connections": [["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"]],
            "preferredConnectionId": "pipe:1",
        ])]))
        #expect(snapshot.hosts.isEmpty)
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Pipe only"))
    }

    @Test("carries a direct host's password through")
    func password() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [["id": "d", "type": "directTcp", "endpoint": "10.0.0.9:6767", "useTls": true, "password": "hunter2"]],
            "preferredConnectionId": "d",
        ])]))
        if case .directTcp(_, _, _, let useTls, let password) = try #require(snapshot.hosts.first) {
            #expect(useTls)
            #expect(password == "hunter2")
        } else {
            Issue.record("expected a direct host")
        }
    }

    @Test("keeps every other host when one profile carries a connection type the tray has never seen")
    func unknownConnectionType() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_known"]),
            profile([
                "serverId": "srv_future",
                "label": "Future",
                "connections": [["id": "ws:1", "type": "directWs", "url": "ws://x"]],
                "preferredConnectionId": "ws:1",
            ]),
        ]))
        // The desktop app is not version-pinned: a connection kind it adds
        // tomorrow must cost that one host, named, and nothing else.
        #expect(snapshot.hosts.map(\.id) == ["srv_known"])
        #expect(snapshot.failures.count == 1)
        #expect(try #require(snapshot.failures.first).contains("Future"))
        #expect(try #require(snapshot.failures.first).contains("directWs"))
    }

    @Test("names a profile that does not parse and keeps the rest")
    func malformedProfile() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_ok"]),
            profile(["serverId": "srv_bad", "label": "Broken", "connections": [["id": "d", "type": "directTcp"]]]),
            ["nothing": true],
        ]))
        #expect(snapshot.hosts.map(\.id) == ["srv_ok"])
        #expect(snapshot.failures.count == 2)
        // A known kind with a malformed shape is a profile-level failure that
        // says what was missing.
        #expect(try #require(snapshot.failures.first).contains("Broken"))
        #expect(try #require(snapshot.failures.first).contains("endpoint"))
        // With nothing to name it by, the row falls back to the position.
        #expect(snapshot.failures[1].contains("profile 3"))
    }

    @Test("trims a serverId the way the Paseo app does before using it as the host id")
    func trimsServerId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile(["serverId": "  srv_pad  "])]))
        // For a relay host this string is sent as the session id, so a stray
        // space is a host that never connects.
        #expect(snapshot.hosts.first?.id == "srv_pad")
    }

    @Test("accepts a connection without an id, as the app's own schema does")
    func connectionWithoutId() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([profile([
            "connections": [["type": "directTcp", "endpoint": "10.0.0.9:6767"]],
            "preferredConnectionId": NSNull(),
        ])]))
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.hosts.count == 1)
    }

    @Test("treats a null or empty label as no label")
    func emptyLabels() throws {
        let snapshot = try PaseoRegistry.hostEntries(fromJSON: try json([
            profile(["serverId": "srv_null", "label": NSNull()]),
            profile(["serverId": "srv_empty", "label": ""]),
            profile([
                "serverId": "srv_empty_pipe",
                "label": "",
                "connections": [["id": "pipe:1", "type": "directPipe", "path": "/tmp/sock"]],
            ]),
        ]))
        #expect(snapshot.hosts.map(\.label) == [nil, nil])
        // An empty name would open a failure row with a bare dash.
        #expect(try #require(snapshot.failures.first).hasPrefix("srv_empty_pipe "))
    }

    @Test("throws on JSON that is not an array of profiles")
    func notAnArray() {
        #expect(throws: RegistryError.notAnArray) {
            try PaseoRegistry.hostEntries(fromJSON: "{\"nope\":true}")
        }
    }

    @Test("throws on malformed JSON rather than returning an empty host list")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            try PaseoRegistry.hostEntries(fromJSON: "{{{")
        }
    }
}

struct PaseoRegistryDirectoryTests {
    private func seedLevelDbDir(_ appSupport: URL, _ appDir: String) throws -> URL {
        let dir = appSupport.appendingPathComponent("\(appDir)/Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("returns the Paseo path when that directory exists")
    func found() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let expected = try seedLevelDbDir(appSupport, "Paseo")
        #expect(try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path) == expected.path)
    }

    @Test("does not probe a development build's directory, whose storage is keyed under another origin")
    func ignoresDevBuild() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        _ = try seedLevelDbDir(appSupport, "@getpaseo/desktop")
        #expect(throws: RegistryError.self) {
            try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
        }
    }

    @Test("throws naming the probed path when it does not exist")
    func namesPath() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        do {
            _ = try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
            Issue.record("expected levelDbDir to throw")
        } catch let error as RegistryError {
            #expect(error.message.contains("\(appSupport.path)/Paseo/Local Storage/leveldb"))
            #expect(error.message.contains("not found"))
        }
    }

    @Test("reports a directory it cannot reach as its own problem, not as the app being absent")
    func notADirectory() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        // A regular file where the `Paseo` directory should be: `access` fails
        // with ENOTDIR, not ENOENT. Telling the user to install Paseo would be wrong.
        try Data("not a directory".utf8).write(to: appSupport.appendingPathComponent("Paseo"))
        do {
            _ = try PaseoRegistry.levelDbDir(appSupportDir: appSupport.path)
            Issue.record("expected levelDbDir to throw")
        } catch let error as RegistryError {
            #expect(!error.message.contains("not found"))
            #expect(error.message.contains("ENOTDIR"))
        }
    }

    @Test("returns nil when the directory exists but holds no registry key")
    func noRegistryKey() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("deleted", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path) == nil)
    }

    @Test("returns mapped hosts when pointed at a real fixture")
    func realFixture() throws {
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("log-only", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path) == RegistrySnapshot(
            hosts: [.directTcp(id: "srv_fixture01", label: "log-only", endpoint: "localhost:6767", useTls: false, password: nil)],
            failures: []
        ))
    }

    @Test("reads a registry stored with the UTF-16LE value encoding")
    func utf16Fixture() throws {
        // Chromium picks the encoding per value, so both tags are reachable
        // from the same database.
        let appSupport = try RegistryFixtures.temporaryDirectory("paseo-registry")
        let dir = try seedLevelDbDir(appSupport, "Paseo")
        try RegistryFixtures.copy("utf16", into: dir)
        #expect(try PaseoRegistry.read(appSupportDir: appSupport.path)?.hosts.first?.label == "utf16")
    }
}
