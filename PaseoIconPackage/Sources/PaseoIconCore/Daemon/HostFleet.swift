import Foundation

/// Owns the set of live host connections and the config generation they were
/// built from. Everything here is the connection bookkeeping that can actually
/// go wrong, so it holds no AppKit and takes its collaborators by injection.
///
/// Unlike the Electron original this is synchronous: `HostConnection.close()`
/// returns immediately rather than awaiting a socket, so there is no await
/// point for two applies to interleave through and no serialization to do.
@MainActor
public final class HostFleet {
    public typealias MakeConnection = (HostEntry, HostStore) throws -> any HostConnecting

    private let store: HostStore
    private let onEntryFailures: ([String]) -> Void
    private let makeConnection: MakeConnection

    private var connections: [String: any HostConnecting] = [:]
    /// The entries behind the live connections, in config order. A menu row
    /// carries only a hostId, and both the web fallback and the per-host retry
    /// need the entry itself.
    private var appliedHosts: [(id: String, entry: HostEntry)] = []
    /// The unusable entries behind the caller's error row, keyed by entry id
    /// so a retry can clear its own without disturbing the other hosts'.
    private var entryFailures: [(id: String, message: String)] = []
    /// Optional rather than empty: `hostsFingerprint` returns `""` if encoding
    /// ever fails, and an empty initial value would make that first apply a
    /// silent no-op — no hosts, no error row, nothing to click. Nothing can be
    /// equal to "not applied yet".
    private var appliedFingerprint: String?

    public init(
        store: HostStore,
        onEntryFailures: @escaping ([String]) -> Void,
        makeConnection: MakeConnection? = nil
    ) {
        self.store = store
        self.onEntryFailures = onEntryFailures
        self.makeConnection = makeConnection ?? { entry, store in
            try HostConnection(entry: entry, sink: store, clock: ContinuousClock())
        }
    }

    /// Rebuilds the fleet to match `config`. No-ops when the host list is
    /// unchanged: Chromium rewrites the registry's database for keys the tray
    /// does not care about, and churning sockets over that is pure cost.
    public func apply(_ config: AppConfig) {
        let fingerprint = hostsFingerprint(config.hosts)
        if fingerprint == appliedFingerprint { return }
        // Recorded only once the fleet is actually built. Claiming it up front
        // meant a rebuild that died partway still looked applied. `nil` rather
        // than empty for the same reason the declaration is optional: `""` is a
        // value `hostsFingerprint` can return.
        appliedFingerprint = nil

        closeAll()
        appliedHosts.removeAll()
        entryFailures.removeAll()

        for entry in config.hosts {
            appliedHosts.append((entry.id, entry))
            connect(entry)
        }

        appliedFingerprint = fingerprint
        reportEntryFailures()
    }

    /// Rebuilds one host. Auth rejection disposes its session for good, so
    /// without this a password fixed on the daemon side has no recovery path
    /// short of relaunching: the registry bytes never changed, so a reload
    /// cannot help.
    public func retry(_ hostId: String) {
        guard let entry = appliedHosts.first(where: { $0.id == hostId })?.entry else { return }
        // `close()` removes the host from the store, so the old connection goes
        // first; building the replacement first would leave a live connection
        // the store can no longer see.
        connections.removeValue(forKey: hostId)?.close()
        connect(entry)
        reportEntryFailures()
    }

    /// The base URL of the host's own web UI, when it has one.
    public func webBaseUrl(for hostId: String) -> String? {
        appliedHosts.first(where: { $0.id == hostId })?.entry.webBaseUrl
    }

    /// The web UI of the first host that is actually connected, in config
    /// order: the fallback used to open Paseo when the desktop app is absent.
    /// Any other status still yields a URL from the entry alone, which would
    /// suppress the `paseo://` fallback in favour of a browser tab that cannot
    /// load.
    public func firstWebBaseUrl() -> String? {
        let statuses = Dictionary(store.snapshot().map { ($0.hostId, $0.status) }, uniquingKeysWith: { first, _ in first })
        for host in appliedHosts where statuses[host.id] == .connected {
            if let url = host.entry.webBaseUrl { return url }
        }
        return nil
    }

    /// Closes in config order rather than the connection map's. A dictionary
    /// has no order, so teardown would otherwise vary run to run, which makes
    /// both the logs and the tests non-reproducible.
    public func closeAll() {
        for host in appliedHosts {
            if let connection = connections.removeValue(forKey: host.id) {
                connection.close()
            } else {
                // A host whose connection could not be built still has a store
                // row — `connect`'s catch registers one so the menu can show
                // `invalid` — but no connection, and `close()` is the only
                // thing that removes a row. Without this the row survives every
                // later `apply`: after the user deletes that host in the Paseo
                // app it stays as a ghost with no explanation and no retry,
                // still counted in `hosts.count`, which flips the host label on
                // for someone who now has a single host.
                store.removeHost(host.id)
            }
        }
        // Anything left is a connection whose entry is already gone; close it
        // rather than leak the socket.
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    /// Creates one host's connection, recording a failure description under
    /// `entry.id` when it cannot. One unusable entry must not take down every
    /// host after it: it shows as a host that exists and cannot be used, named
    /// in the error row.
    private func connect(_ entry: HostEntry) {
        do {
            // The invariant is checked rather than repaired: `AppConfig.validate`
            // rejects duplicate ids and `apply` clears the map before rebuilding,
            // so a call site that breaks it gets a named configuration error
            // instead of a live connection nothing can close.
            if connections[entry.id] != nil {
                throw FleetError.duplicateId(entry.id)
            }
            connections[entry.id] = try makeConnection(entry, store)
            entryFailures.removeAll { $0.id == entry.id }
        } catch {
            let hint = entry.endpointHint
            store.setHost(entry.id, label: entry.label, endpointHint: hint)
            store.setStatus(entry.id, .invalid)
            // Named the way `resolveHostName`'s last resort is: an unlabeled
            // entry never connected, so its own endpoint is the best identifier.
            let message = "\(entry.label ?? hint): \(errorText(error))"
            if let index = entryFailures.firstIndex(where: { $0.id == entry.id }) {
                entryFailures[index] = (entry.id, message)
            } else {
                entryFailures.append((entry.id, message))
            }
        }
    }

    private func reportEntryFailures() {
        onEntryFailures(entryFailures.map(\.message))
    }
}

public enum FleetError: MessageError, Equatable {
    case duplicateId(String)

    public var message: String {
        switch self {
        case .duplicateId(let id): "a connection for host id \"\(id)\" already exists"
        }
    }
}

extension HostEntry {
    /// The daemon serves its web UI on the same endpoint it serves the socket
    /// on, so a direct host doubles as the fallback target. A relay host has
    /// no such URL: the relay is a socket tunnel, not an HTTP origin.
    public var webBaseUrl: String? {
        guard case .directTcp(_, _, let endpoint, let useTls, _) = self else { return nil }
        return "\(useTls ? "https" : "http")://\(endpoint)"
    }
}
