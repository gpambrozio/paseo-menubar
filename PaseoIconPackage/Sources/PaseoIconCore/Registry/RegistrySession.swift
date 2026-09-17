import Foundation

/// Owns the tray's view of the Paseo app's host registry: when to re-read
/// it, whether anything changed, and what the error row says. Nothing here
/// throws out of `start` or `refresh`: a menu bar app that dies on a torn
/// read of another program's database leaves the user nothing to fix it
/// with.
@MainActor
public final class RegistrySession {
    public static let noHostsMessage = "No hosts yet. Pair a host in the Paseo app."

    private let readRegistry: () async throws -> RegistrySnapshot?
    private let watch: (@escaping () -> Void) -> () -> Void
    private let applyConfig: (AppConfig) async throws -> Void
    private let onConfigError: (String?) -> Void
    private let afterRead: (() -> Void)?
    private let pollInterval: Duration
    private let debounce: Duration
    private let clock: any Clock<Duration>

    private var appliedFingerprint: String?
    private var stopWatching: (() -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var chain: Task<Void, Never>?

    // Two independent problems, reported through one menu row: reading the
    // registry, and entries the fleet could not use. Neither may clear the other.
    private var registryError: String?
    private var fleetError: String?

    /// - Parameters:
    ///   - readRegistry: production passes `PaseoRegistry.read`.
    ///   - watch: starts watching; returns the stop function.
    ///   - afterRead: runs after every read, failed ones included. Production
    ///     re-attaches the directory watch here, which is what makes installing
    ///     Paseo mid-session take effect on the next poll.
    ///   - pollInterval: safety net for events the watcher misses. Zero disables it.
    public init(
        readRegistry: @escaping () async throws -> RegistrySnapshot?,
        watch: @escaping (@escaping () -> Void) -> () -> Void,
        applyConfig: @escaping (AppConfig) async throws -> Void,
        onConfigError: @escaping (String?) -> Void,
        afterRead: (() -> Void)? = nil,
        pollInterval: Duration = .seconds(60),
        debounce: Duration = .milliseconds(500),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.readRegistry = readRegistry
        self.watch = watch
        self.applyConfig = applyConfig
        self.onConfigError = onConfigError
        self.afterRead = afterRead
        self.pollInterval = pollInterval
        self.debounce = debounce
        self.clock = clock
    }

    /// Reads once and applies. Never throws.
    public func start() async {
        stopWatching = watch { [weak self] in self?.scheduleDebouncedRefresh() }
        if pollInterval > .zero {
            pollTask = Task { [weak self] in
                while true {
                    guard let self else { return }
                    do { try await self.clock.sleep(for: self.pollInterval) } catch { return }
                    await self.refresh()
                }
            }
        }
        await refresh()
    }

    /// Re-reads. Never throws. Reads are serialized so a watcher burst cannot
    /// interleave two applies.
    public func refresh() async {
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.readAndApply()
        }
        chain = task
        await task.value
    }

    /// The fleet's unusable entries, for the half of the error row it owns.
    public func noteEntryFailures(_ failures: [String]) {
        fleetError = failures.isEmpty ? nil : Self.describeUnusableHosts(failures)
        refreshConfigError()
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        // The read chain too. On quit `AppCoordinator.stop()` closes the fleet
        // while a read may still be awaiting its detached LevelDB work; when it
        // resumed it called `applyConfig` and rebuilt every connection during
        // teardown. The process is going away either way, but shutdown should
        // mean what it says.
        chain?.cancel()
        chain = nil
        stopWatching?()
        stopWatching = nil
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(for: self.debounce) } catch { return }
            self.debounceTask = nil
            await self.refresh()
        }
    }

    private static func describeUnusableHosts(_ failures: [String]) -> String {
        "These hosts could not be used:\n\n\(failures.joined(separator: "\n"))"
    }

    private func refreshConfigError() {
        let problems = [registryError, fleetError].compactMap { $0 }
        onConfigError(problems.isEmpty ? nil : problems.joined(separator: "\n\n"))
    }

    /// One read, start to finish, that cannot throw.
    private func readAndApply() async {
        await readOnce()
        afterRead?()
    }

    private func readOnce() async {
        let snapshot: RegistrySnapshot?
        do {
            snapshot = try await readRegistry()
        } catch {
            // Keep the last known-good host set live and say what went wrong.
            registryError = errorText(error)
            refreshConfigError()
            return
        }

        let hosts = snapshot?.hosts ?? []
        let failures = snapshot?.failures ?? []

        var problems: [String] = []
        // Absent key and empty array are the same dead end for the user.
        if hosts.isEmpty && failures.isEmpty { problems.append(Self.noHostsMessage) }
        if let warning = snapshot?.warning { problems.append(warning) }
        if !failures.isEmpty { problems.append(Self.describeUnusableHosts(failures)) }

        // The host set is hand-built from another program's storage, so it is
        // validated before the fleet sees it; this is the only path that builds a config.
        let config: AppConfig
        do {
            config = try AppConfig.validate(hosts: hosts)
        } catch {
            problems.append("The Paseo app's host list could not be used:\n\n\(errorText(error))")
            registryError = problems.joined(separator: "\n\n")
            refreshConfigError()
            return
        }

        registryError = problems.isEmpty ? nil : problems.joined(separator: "\n\n")
        refreshConfigError()

        // Rebuilding tears down live connections, so only when the host set differs.
        let fingerprint = hostsFingerprint(config.hosts)
        if fingerprint == appliedFingerprint { return }
        do {
            try await applyConfig(config)
            // Recorded only once the fleet has actually taken it.
            appliedFingerprint = fingerprint
        } catch {
            // The fleet may be half torn down, so nothing counts as applied any more.
            appliedFingerprint = nil
            problems.append("The hosts could not be applied:\n\n\(errorText(error))")
            registryError = problems.joined(separator: "\n\n")
            refreshConfigError()
        }
    }
}
