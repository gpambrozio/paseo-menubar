import Foundation
import Testing
@testable import PaseoIconCore

/// The one file in the registry stack with no TypeScript counterpart, and the
/// only one that talks to a C API. Every other watcher test injects a fake
/// `open`, so without this nothing exercises the real callback at all — and
/// the first version of it crashed on its first event.
@MainActor
struct FSEventsWatchTests {
    @Test("delivers a change for a file the reader opens, and not for one it ignores")
    func deliversRelevantChanges() async throws {
        let dir = try RegistryFixtures.temporaryDirectory("fsevents")
        var changes = 0
        var errors = 0
        let stop = try FSEventsWatch.open(directory: dir.path, onChange: { changes += 1 }, onError: { errors += 1 })
        defer { stop() }

        // A bookkeeping file the registry reader never opens.
        try Data("x".utf8).write(to: dir.appendingPathComponent("LOG"))
        // Give the stream a chance to deliver the irrelevant event before the
        // relevant one, so a pass cannot come from the two being coalesced.
        try await Task.sleep(for: .milliseconds(600))
        let beforeRelevant = changes

        // The filter is the whole job of `handle`: LOG is a file the registry
        // reader never opens, and Chromium rewrites it constantly. Without this
        // assertion the test passes even with the filename filter removed
        // entirely — checked by mutation.
        #expect(beforeRelevant == 0, "an event for a file the reader ignores must not trigger a re-read")

        try Data("y".utf8).write(to: dir.appendingPathComponent("000001.log"))
        #expect(await eventually(timeout: .seconds(10)) { changes > beforeRelevant })
        #expect(errors == 0)
    }

    @Test("reports the watch as dead when its directory is replaced")
    func reportsRootChange() async throws {
        let parent = try RegistryFixtures.temporaryDirectory("fsevents-root")
        let watched = parent.appendingPathComponent("leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        var errors = 0
        let stop = try FSEventsWatch.open(directory: watched.path, onChange: {}, onError: { errors += 1 })
        defer { stop() }

        // What a reinstall of the Paseo app does. The watcher has to hear about
        // it, or the tray sits on the poll for the life of the process.
        try FileManager.default.removeItem(at: watched)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        #expect(await eventually(timeout: .seconds(10)) { errors > 0 })
    }

    @Test("stopping twice is safe, and stops delivering")
    func stopIsIdempotent() async throws {
        let dir = try RegistryFixtures.temporaryDirectory("fsevents-stop")
        var changes = 0
        let stop = try FSEventsWatch.open(directory: dir.path, onChange: { changes += 1 }, onError: {})
        stop()
        stop()
        try Data("y".utf8).write(to: dir.appendingPathComponent("000001.log"))
        try await Task.sleep(for: .milliseconds(800))
        #expect(changes == 0)
    }
}
