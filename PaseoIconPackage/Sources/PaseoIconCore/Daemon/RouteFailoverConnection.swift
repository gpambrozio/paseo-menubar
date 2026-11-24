import Foundation

/// Owns the ordered routes for one host. The selected route serves the host
/// until it fails, and all attempts share the same store row.
@MainActor
final class RouteFailoverConnection: HostConnecting {
    private let entries: [HostEntry]
    private let sink: any HostSink
    private let clock: any Clock<Duration>
    private let makeConnection: (HostEntry, any HostSink) throws -> any HostConnecting
    private let hostId: String

    private var connection: (any HostConnecting)?
    private var attemptSink: AttemptSink?
    private var advanceTask: Task<Void, Never>?
    private var failuresInCycle = 0
    private var cycleDelay: Duration = .milliseconds(1500)
    private var closed = false

    init(
        entries: [HostEntry],
        sink: any HostSink,
        clock: any Clock<Duration>,
        makeConnection: @escaping (HostEntry, any HostSink) throws -> any HostConnecting
    ) throws {
        guard let first = entries.first, entries.allSatisfy({ $0.id == first.id }) else {
            throw RouteError.invalidHost
        }
        self.entries = entries
        self.sink = sink
        self.clock = clock
        self.makeConnection = makeConnection
        hostId = first.id
        try startAttempt(at: entries.startIndex)
    }

    func close() {
        guard !closed else { return }
        closed = true
        advanceTask?.cancel()
        advanceTask = nil
        retireAttempt()
        sink.removeHost(hostId)
    }

    private func startAttempt(at index: Int) throws {
        let entry = entries[index]
        let proxy = AttemptSink(owner: self, index: index)
        attemptSink = proxy
        do {
            let next = try makeConnection(entry, proxy)
            if closed {
                next.close()
            } else {
                connection = next
            }
        } catch {
            advanceTask?.cancel()
            advanceTask = nil
            retireAttempt()
            throw error
        }
    }

    private func retireAttempt() {
        attemptSink = nil
        let previous = connection
        connection = nil
        previous?.close()
    }

    private func receiveStatus(_ status: HostStatus, from proxy: AttemptSink) {
        guard attemptSink === proxy else { return }
        switch status {
        case .connecting:
            break
        case .connected:
            advanceTask?.cancel()
            advanceTask = nil
            failuresInCycle = 0
            cycleDelay = .milliseconds(1500)
        case .disconnected:
            scheduleAdvance(after: proxy.index)
        case .unauthorized, .securityRejected, .incompatibleProtocol, .invalid:
            advanceTask?.cancel()
            attemptSink = nil
            advanceTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.advanceTask = nil
                self.retireAttempt()
            }
        }
        sink.setStatus(hostId, status)
    }

    private func scheduleAdvance(after index: Int) {
        guard advanceTask == nil else { return }
        failuresInCycle += 1
        let delay: Duration?
        if failuresInCycle == entries.count {
            failuresInCycle = 0
            delay = cycleDelay
            cycleDelay = min(cycleDelay * 2, .seconds(30))
        } else {
            delay = nil
        }

        let nextIndex = entries.index(after: index)
        let next = nextIndex == entries.endIndex ? entries.startIndex : nextIndex
        // Defer teardown outside the session's status callback. The old
        // session's own reconnect and seed retries are canceled by close().
        let clock = self.clock
        advanceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.retireAttempt()
            if let delay {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.advanceTask = nil
            do {
                try self.startAttempt(at: next)
            } catch {
                self.sink.setStatus(self.hostId, .invalid)
            }
        }
    }

    private enum RouteError: MessageError {
        case invalidHost

        var message: String { "host routes must share one host ID" }
    }

    @MainActor
    private final class AttemptSink: HostSink {
        weak var owner: RouteFailoverConnection?
        let index: Int

        init(owner: RouteFailoverConnection, index: Int) {
            self.owner = owner
            self.index = index
        }

        private func sink(for hostId: String) -> (any HostSink)? {
            guard let owner, owner.hostId == hostId, owner.attemptSink === self else { return nil }
            return owner.sink
        }

        func setHost(_ hostId: String, label: String?, endpointHint: String) {
            sink(for: hostId)?.setHost(hostId, label: label, endpointHint: endpointHint)
        }

        // Only the outer connection owns the row's lifetime.
        func removeHost(_ hostId: String) {}

        func setStatus(_ hostId: String, _ status: HostStatus) {
            guard let owner, owner.hostId == hostId else { return }
            owner.receiveStatus(status, from: self)
        }

        func setServerId(_ hostId: String, _ serverId: String) {
            sink(for: hostId)?.setServerId(hostId, serverId)
        }

        func setHostname(_ hostId: String, _ hostname: String?) {
            sink(for: hostId)?.setHostname(hostId, hostname)
        }

        func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
            sink(for: hostId)?.seedAgents(hostId, agents, truncated: truncated)
        }

        func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
            sink(for: hostId)?.seedWorkspaces(hostId, workspaces, truncated: truncated)
        }

        func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) {
            sink(for: hostId)?.applyAgentUpdate(hostId, update)
        }

        func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) {
            sink(for: hostId)?.applyWorkspaceUpdate(hostId, update)
        }
    }
}
