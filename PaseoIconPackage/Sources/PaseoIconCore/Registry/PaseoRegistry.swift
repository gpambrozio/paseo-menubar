import Foundation

/// The hosts the Paseo desktop app has stored, as the tray can use them.
public struct RegistrySnapshot: Equatable, Sendable {
    public var hosts: [HostEntry]
    /// Additional relay routes in registry order, keyed by the primary host id.
    public var fallbackHosts: [String: [HostEntry]]
    /// Hosts the tray cannot dial, phrased for the error row. Never silent.
    public var failures: [String]
    /// Set when the hosts above were read out of a database that was partly
    /// unreadable, so they may be superseded.
    public var warning: String?

    public init(
        hosts: [HostEntry], failures: [String], warning: String? = nil, fallbackHosts: [String: [HostEntry]] = [:]
    ) {
        self.hosts = hosts
        self.fallbackHosts = fallbackHosts
        self.failures = failures
        self.warning = warning
    }
}

public enum RegistryError: MessageError, Equatable {
    case notAnArray
    case invalidJSON(String)
    case appNotFound(dir: String)
    case storageUnreachable(dir: String, detail: String)

    public var message: String {
        switch self {
        case .notAnArray: "The registry record is not an array of profiles"
        case .invalidJSON(let detail): "The registry record is not valid JSON: \(detail)"
        case .appNotFound(let dir): "Paseo desktop app not found.\n\nLooked in:\n\(dir)"
        case .storageUnreachable(let dir, let detail): "Could not open the Paseo app's storage at \(dir): \(detail)"
        }
    }
}

/// Reads the Paseo desktop app's host registry out of its Chromium
/// localStorage. An unsupported surface: nothing upstream promises the
/// location, the key, or the value encoding. The payload's shape is the
/// published connection schemas, and that part is safe.
public enum PaseoRegistry {
    public static let origin = "paseo://app"
    public static let registryKey = "@paseo:daemon-registry"
    /// The shipped app's support directory. A development build loads from
    /// the dev server and keys its storage under another origin, so it is
    /// deliberately not probed.
    static let appDirectory = "Paseo"
    static let localStorageSubpath = "Local Storage/leveldb"
    static let knownConnectionTypes: Set<String> = ["directTcp", "relay", "directSocket", "directPipe"]

    /// The leveldb directory of the installed Paseo app. Absent is a distinct,
    /// actionable state ("the app is not installed"); any other reason it
    /// cannot be reached is reported with its own error.
    public static func levelDbDir(appSupportDir: String) throws -> String {
        let dir = (appSupportDir as NSString).appendingPathComponent(appDirectory) + "/" + localStorageSubpath
        if access(dir, F_OK) == 0 { return dir }
        let code = errno
        if code == ENOENT { throw RegistryError.appNotFound(dir: dir) }
        let detail = "\(String(cString: strerror(code))) (\(posixName(code)))"
        throw RegistryError.storageUnreachable(dir: dir, detail: detail)
    }

    /// Nil means the app is installed but has never stored a registry.
    public static func read(appSupportDir: String, fileSystem: any FileSystem = LocalFileSystem()) throws -> RegistrySnapshot? {
        let dir = try levelDbDir(appSupportDir: appSupportDir)
        let result = try LevelDBReader.readValue(directory: dir, userKey: LocalStorage.key(origin: origin, key: registryKey), fileSystem: fileSystem)
        guard let value = result.value else { return nil }
        var snapshot = try hostEntries(fromJSON: try LocalStorage.decodeValue(value))
        // A value found next to an unreadable file is usable but not the last word.
        snapshot.warning = result.parseFailure
        return snapshot
    }

    /// Maps the stored profiles to host entries. Anything but an array fails
    /// the whole read; one profile that does not parse is named and skipped,
    /// because losing the others over a sibling is the silent cap this
    /// project forbids.
    public static func hostEntries(fromJSON json: String) throws -> RegistrySnapshot {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw RegistryError.invalidJSON(errorText(error))
        }
        guard let candidates = parsed as? [Any] else { throw RegistryError.notAnArray }

        var hosts: [HostEntry] = []
        var fallbackHosts: [String: [HostEntry]] = [:]
        var failures: [String] = []
        var seenServerIds = Set<String>()

        for (index, candidate) in candidates.enumerated() {
            let name = describeProfile(candidate, index: index)
            let profile: Profile
            do {
                profile = try Profile(candidate)
            } catch let error as ProfileError {
                failures.append("\(name) — could not be read (\(error.issues.joined(separator: "; ")))")
                continue
            }

            let routes: [HostEntry]
            do {
                routes = try profile.hostRoutes()
            } catch {
                failures.append("\(name) — \(errorText(error))")
                continue
            }

            guard let primary = routes.first else {
                let kinds = profile.connections.map(\.type)
                let has = kinds.isEmpty ? "" : " (has: \(kinds.joined(separator: ", ")))"
                failures.append("\(name) — no connection the menu bar can use\(has)")
                continue
            }

            // Two profiles for one daemon: the id keys the fleet's connection
            // map, so the first wins and the second is named.
            if seenServerIds.contains(profile.serverId) {
                failures.append("\(name) — a second profile for host \(profile.serverId); the menu bar shows the first")
                continue
            }
            seenServerIds.insert(profile.serverId)

            hosts.append(primary)
            if routes.count > 1 {
                fallbackHosts[primary.id] = Array(routes.dropFirst())
            }
        }
        return RegistrySnapshot(hosts: hosts, failures: failures, fallbackHosts: fallbackHosts)
    }

    // MARK: - Profile parsing

    private struct ProfileError: Error {
        let issues: [String]
    }

    private enum Dialable {
        case directTcp(endpoint: String, useTls: Bool, password: String?)
        case relay(endpoint: String, useTls: Bool?, daemonPublicKeyB64: String, minimumSecurityMode: RelaySecurityMode?)
    }

    private struct Connection {
        let id: String?
        let type: String
        let dialable: Dialable?
    }

    /// One stored profile, validated the way the published schemas validated
    /// it: a known connection kind with a malformed shape is an issue, an
    /// unknown kind is merely unusable.
    private struct Profile {
        let serverId: String
        let label: String?
        let password: String?
        let connections: [Connection]
        let preferredConnectionId: String?

        init(_ candidate: Any) throws {
            guard let object = candidate as? [String: Any] else { throw ProfileError(issues: ["profile: expected an object"]) }
            var issues: [String] = []

            var serverId = ""
            if let raw = object["serverId"] as? String {
                serverId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if serverId.isEmpty { issues.append("serverId: must not be empty") }
            } else {
                issues.append("serverId: required")
            }

            var label: String?
            if let raw = object["label"] {
                if let text = raw as? String { label = text } else if !(raw is NSNull) { issues.append("label: expected a string") }
            }

            var password: String?
            if let raw = object["password"] {
                if let text = raw as? String { password = text } else { issues.append("password: expected a string") }
            }

            var connections: [Connection] = []
            if let rawConnections = object["connections"] as? [Any] {
                for (index, raw) in rawConnections.enumerated() {
                    guard let entry = raw as? [String: Any], let type = entry["type"] as? String else {
                        issues.append("connections.\(index): expected an object with a type")
                        continue
                    }
                    let id = entry["id"] as? String
                    let prefix = "connections.\(index)"
                    switch type {
                    case "directTcp":
                        guard let endpoint = entry["endpoint"] as? String else { issues.append("\(prefix).endpoint: required"); continue }
                        var useTls = false
                        if let raw = entry["useTls"] { if let flag = PaseoRegistry.boolValue(raw) { useTls = flag } else { issues.append("\(prefix).useTls: expected a boolean"); continue } }
                        var password: String?
                        if let raw = entry["password"] { if let text = raw as? String { password = text } else { issues.append("\(prefix).password: expected a string"); continue } }
                        connections.append(Connection(id: id, type: type, dialable: .directTcp(endpoint: endpoint, useTls: useTls, password: password)))
                    case "relay":
                        guard let endpoint = entry["relayEndpoint"] as? String else { issues.append("\(prefix).relayEndpoint: required"); continue }
                        guard let key = entry["daemonPublicKeyB64"] as? String else { issues.append("\(prefix).daemonPublicKeyB64: required"); continue }
                        var useTls: Bool?
                        if let raw = entry["useTls"] { if let flag = PaseoRegistry.boolValue(raw) { useTls = flag } else { issues.append("\(prefix).useTls: expected a boolean"); continue } }
                        var minimumSecurityMode: RelaySecurityMode?
                        if let raw = entry["minimumSecurityMode"] {
                            guard (raw as? String) == "protected" else {
                                issues.append("\(prefix).minimumSecurityMode: expected protected")
                                continue
                            }
                            minimumSecurityMode = .protected
                        }
                        connections.append(Connection(id: id, type: type, dialable: .relay(
                            endpoint: endpoint, useTls: useTls, daemonPublicKeyB64: key,
                            minimumSecurityMode: minimumSecurityMode
                        )))
                    case "directSocket", "directPipe":
                        guard entry["path"] is String else { issues.append("\(prefix).path: required"); continue }
                        connections.append(Connection(id: id, type: type, dialable: nil))
                    default:
                        // A kind the tray has never seen reduces to "unusable", not to a rejected profile.
                        connections.append(Connection(id: id, type: type, dialable: nil))
                    }
                }
            } else {
                issues.append("connections: required")
            }

            var preferred: String?
            if let raw = object["preferredConnectionId"] {
                if let text = raw as? String { preferred = text } else if !(raw is NSNull) { issues.append("preferredConnectionId: expected a string") }
            }

            guard issues.isEmpty else { throw ProfileError(issues: issues) }
            self.serverId = serverId
            self.label = label
            self.password = password == "" ? nil : password
            self.connections = connections
            self.preferredConnectionId = preferred
        }

        /// The desktop's preferred supported connection leads. Automatic
        /// fallback stays within the same relay identity and wire server id.
        func hostRoutes() throws -> [HostEntry] {
            var supported = connections.filter { $0.dialable != nil }
            if let preferred = supported.firstIndex(where: { $0.id != nil && $0.id == preferredConnectionId }) {
                let connection = supported.remove(at: preferred)
                supported.insert(connection, at: 0)
            }

            let label = self.label.flatMap { $0.isEmpty ? nil : $0 }
            switch supported.first?.dialable {
            case .directTcp(let endpoint, let useTls, let routePassword):
                _ = try DaemonEndpoints.daemonWebSocketURL(endpoint: endpoint, useTls: useTls)
                return [.directTcp(
                    id: serverId, label: label, endpoint: endpoint, useTls: useTls,
                    password: password ?? routePassword
                )]
            case .relay(let endpoint, let useTls, let key, let minimumMode):
                let primary = try ConnectionOffer(
                    serverId: serverId, daemonPublicKeyB64: key, relay: .init(endpoint: endpoint, useTls: useTls),
                    minimumSecurityMode: minimumMode
                ).validated()
                let primaryURL = try primary.relayWebSocketURL()
                let identity = try RelaySecurityPinStore.identity(publicKeyB64: key)
                var offers = [primary]
                var seen: Set<URL> = [primaryURL]
                var requiresProtected = minimumMode == .protected
                for route in supported.dropFirst() {
                    guard case .relay(let endpoint, let useTls, let key, let minimumMode) = route.dialable,
                          (try? RelaySecurityPinStore.identity(publicKeyB64: key)) == identity else { continue }
                    // A duplicate or unusable endpoint can still advertise
                    // the minimum for this daemon.
                    requiresProtected = requiresProtected || minimumMode == .protected
                    let offer = ConnectionOffer(
                        serverId: serverId, daemonPublicKeyB64: key, relay: .init(endpoint: endpoint, useTls: useTls),
                        minimumSecurityMode: minimumMode
                    )
                    guard let url = try? offer.relayWebSocketURL(), seen.insert(url).inserted else { continue }
                    offers.append(offer)
                }
                return offers.map { offer in
                    var offer = offer
                    if requiresProtected { offer.minimumSecurityMode = .protected }
                    return .relay(id: serverId, label: label, offer: offer, password: password)
                }
            case nil:
                return []
            }
        }
    }

    /// The best name for a profile that may not have parsed: label, serverId,
    /// else its position.
    private static func describeProfile(_ candidate: Any, index: Int) -> String {
        if let object = candidate as? [String: Any] {
            if let label = object["label"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
            if let serverId = object["serverId"] as? String, !serverId.trimmingCharacters(in: .whitespaces).isEmpty { return serverId }
        }
        return "profile \(index + 1)"
    }

    /// `JSONSerialization` returns `NSNumber` for both booleans and integers,
    /// and `as? Bool` bridges 0 and 1 as happily as false and true — so a
    /// profile written with `"useTls": 1` would be accepted where the
    /// published schema rejects it. `CFBoolean` is the only thing that is
    /// really a boolean.
    private static func boolValue(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func posixName(_ code: Int32) -> String {
        switch code {
        case ENOTDIR: "ENOTDIR"
        case EACCES: "EACCES"
        case ELOOP: "ELOOP"
        default: "errno \(code)"
        }
    }
}
