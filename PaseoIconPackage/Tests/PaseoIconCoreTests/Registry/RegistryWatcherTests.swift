import Foundation
import Testing
@testable import PaseoIconCore

@MainActor
struct RegistryWatcherTests {
    @MainActor
    final class OpenCall {
        let dir: String
        let fire: () -> Void
        let fail: () -> Void
        var closed = false

        init(dir: String, fire: @escaping () -> Void, fail: @escaping () -> Void) {
            self.dir = dir
            self.fire = fire
            self.fail = fail
        }
    }

    @MainActor
    final class Harness {
        private(set) var opens: [OpenCall] = []
        private(set) var probes = 0
        var changes = 0
        /// Built after the stored properties so the callbacks can capture self.
        private(set) var watcher: RegistryWatcher!

        init(resolveDir: @escaping () async throws -> String, openThrows: ((Int) -> Bool)? = nil) {
            watcher = RegistryWatcher(
                resolveDir: { [weak self] in
                    self?.probes += 1
                    return try await resolveDir()
                },
                open: { [weak self] dir, onChange, onError in
                    guard let self else { return {} }
                    let attempt = self.opens.count + 1
                    if openThrows?(attempt) == true {
                        // `fs.watch`'s equivalent: the directory vanished
                        // between resolution and the call.
                        self.opens.append(OpenCall(dir: dir, fire: {}, fail: {}))
                        throw FSEventsWatchError.couldNotStart(dir)
                    }
                    let call = OpenCall(dir: dir, fire: onChange, fail: onError)
                    self.opens.append(call)
                    return { call.closed = true }
                }
            )
        }
    }

    @Test("attaches to the resolved directory and forwards changes")
    func attaches() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch { h.changes += 1 }
        await settle()

        #expect(h.opens.count == 1)
        #expect(h.opens.first?.dir == "/db")
        h.opens.first?.fire()
        #expect(h.changes == 1)
    }

    @Test("attaches on a later read when Paseo was not installed at launch")
    func attachesLater() async {
        var installed = false
        let h = Harness(resolveDir: {
            if !installed { throw RegistryError.appNotFound(dir: "/db") }
            return "/db"
        })

        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.isEmpty)

        // Installing Paseo mid-session used to leave the app on the 60-second
        // poll for the life of the process.
        installed = true
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("never throws when the directory cannot be resolved")
    func resolveFailure() async {
        let h = Harness(resolveDir: { throw RegistryError.appNotFound(dir: "/db") })
        // An unhandled error here would be fatal in the app.
        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.isEmpty)
    }

    @Test("does not open a second watch while one is already attached")
    func singleWatch() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch {}
        await settle()
        h.watcher.ensureAttached()
        h.watcher.ensureAttached()
        await settle()

        #expect(h.opens.count == 1)
    }

    @Test("does not probe the directory again while a probe is in flight")
    func singleProbe() async {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/db"
        })

        _ = h.watcher.watch {}
        await settle()
        h.watcher.ensureAttached()
        h.watcher.ensureAttached()
        await settle()

        // `ensureAttached` runs after every read, so without this guard a slow
        // probe would stack one more on each poll.
        #expect(h.probes == 1)
        gate.open()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("re-attaches after the watch reports an error")
    func reattaches() async {
        let h = Harness(resolveDir: { "/db" })
        _ = h.watcher.watch {}
        await settle()

        // macOS drops watches when the watched directory is replaced, which a
        // compaction does. Without a fresh attach the tray is on the poll alone.
        h.opens.first?.fail()
        h.watcher.ensureAttached()
        await settle()

        #expect(h.opens.count == 2)
    }

    @Test("stops watching and stops forwarding once detached")
    func detaches() async {
        let h = Harness(resolveDir: { "/db" })
        let stop = h.watcher.watch { h.changes += 1 }
        await settle()

        stop()
        #expect(h.opens.first?.closed == true)
        h.opens.first?.fire()
        #expect(h.changes == 0)

        // And a read arriving after shutdown must not resurrect it.
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 1)
    }

    @Test("stays detached, and tries again later, when open itself throws")
    func openThrows() async {
        let h = Harness(resolveDir: { "/db" }, openThrows: { $0 == 1 })
        _ = h.watcher.watch {}
        await settle()
        #expect(h.opens.count == 1)

        // A throw must not count as attached, or the tray sits on the poll for
        // the life of the process with a watch it never had.
        h.watcher.ensureAttached()
        await settle()
        #expect(h.opens.count == 2)
    }

    @Test("does not attach a directory that resolves after the watcher was detached")
    func resolvesAfterDetach() async {
        let gate = AsyncGate()
        let h = Harness(resolveDir: {
            await gate.wait()
            return "/db"
        })

        let stop = h.watcher.watch {}
        await settle()
        stop()
        gate.open()
        await settle()

        #expect(h.opens.isEmpty)
    }

    @Test("passes the files the reader opens and drops LevelDB's bookkeeping")
    func fileFilter() {
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000005.ldb"))
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000004.sst"))
        #expect(RegistryWatcher.isRegistryFileEvent("/db/000036.log"))
        for name in ["LOG", "LOG.old", "LOCK", "CURRENT", "MANIFEST-000001", "000037.dbtmp"] {
            #expect(!RegistryWatcher.isRegistryFileEvent("/db/\(name)"), "\(name)")
        }
    }
}

/// A one-shot gate a test opens to release a pending async call.
final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false

    func open() {
        guard !opened else { return }
        opened = true
        semaphore.signal()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }
}
