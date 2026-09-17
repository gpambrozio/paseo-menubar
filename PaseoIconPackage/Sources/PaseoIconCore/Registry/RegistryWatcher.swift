import Foundation

/// Keeps a filesystem watch on the Paseo app's leveldb directory attached,
/// across the directory not existing yet and across the watch failing later.
/// `ensureAttached` is the seam: the session calls it after every read, so
/// the first read that works is also what attaches the watch. Nothing here
/// throws. The watch implementation is injected, which keeps this free of
/// the filesystem and lets the reattachment logic be tested directly.
@MainActor
public final class RegistryWatcher {
    /// Starts one watch and returns its detach function. A failure after the
    /// watch is up is reported through `onError`; a throw here is tolerated,
    /// the watcher stays unattached and the next read tries again.
    public typealias Open = (_ dir: String, _ onChange: @escaping () -> Void, _ onError: @escaping () -> Void) throws -> () -> Void

    private let resolveDir: () async throws -> String
    private let open: Open
    private var notify: (() -> Void)?
    private var detach: (() -> Void)?
    private var resolving = false

    public init(resolveDir: @escaping () async throws -> String, open: @escaping Open) {
        self.resolveDir = resolveDir
        self.open = open
    }

    /// Whether a directory event names a file the reader opens. LevelDB's
    /// bookkeeping files (`LOG`, `MANIFEST-*`, `CURRENT`, `LOCK`) cannot
    /// change the registry's value, so they are not worth a rescan.
    public nonisolated static func isRegistryFileEvent(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".ldb") || name.hasSuffix(".sst") || name.hasSuffix(".log")
    }

    /// Matches `RegistrySession`'s `watch`. Returns the detach function.
    public func watch(_ onChange: @escaping () -> Void) -> () -> Void {
        notify = onChange
        ensureAttached()
        return { [weak self] in
            guard let self else { return }
            self.notify = nil
            let current = self.detach
            self.detach = nil
            current?()
        }
    }

    /// Attaches if nothing is attached. Safe to call on every read; a burst of
    /// reads while the first resolution is pending opens one watch, not one per read.
    public func ensureAttached() {
        guard notify != nil, detach == nil, !resolving else { return }
        resolving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let dir = try await self.resolveDir()
                self.resolving = false
                guard self.notify != nil, self.detach == nil else { return }
                self.detach = try self.open(
                    dir,
                    { [weak self] in self?.notify?() },
                    // The watch died. Forget it so the next ensureAttached opens a fresh one.
                    { [weak self] in self?.detach = nil }
                )
            } catch {
                // Paseo is not installed, or the directory vanished between
                // resolution and open. Nothing is attached; the next read tries again.
                self.resolving = false
            }
        }
    }
}
