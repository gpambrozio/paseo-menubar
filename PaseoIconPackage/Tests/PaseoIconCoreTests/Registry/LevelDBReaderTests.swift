import Foundation
import Testing
@testable import PaseoIconCore

struct LevelDBReaderTests {
    private let key = RegistryFixtures.registryKey

    private func text(_ value: [UInt8]?) throws -> String {
        RegistryFixtures.latin1(try #require(value))
    }

    /// The value alone, asserting the read reported no damage along the way.
    private func cleanValue(_ dir: URL, _ key: [UInt8], fileSystem: any FileSystem = LocalFileSystem()) throws -> String {
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fileSystem)
        #expect(result.parseFailure == nil)
        return try text(result.value)
    }

    /// A copy of a fixture with one file's bytes rewritten on disk.
    private func copyFixture(_ name: String, corrupting suffix: String? = nil, at byte: Int = 64) throws -> URL {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader")
        try RegistryFixtures.copy(name, into: dir)
        if let suffix {
            let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: suffix).first))
            var bytes = [UInt8](try Data(contentsOf: target))
            bytes[byte] ^= 0xff
            try Data(bytes).write(to: target)
        }
        return dir
    }

    /// A fresh directory holding only the fixture's `.ldb`.
    private func onlyTable(_ name: String, corrupt: Bool = false) throws -> URL {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-table")
        let source = try RegistryFixtures.dir(name)
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        var bytes = [UInt8](try Data(contentsOf: source.appendingPathComponent(file)))
        if corrupt { bytes[64] ^= 0xff }
        try Data(bytes).write(to: dir.appendingPathComponent(file))
        return dir
    }

    @Test("reads a value that lives only in the log")
    func logOnly() throws {
        #expect(try cleanValue(try RegistryFixtures.dir("log-only"), key).contains("log-only"))
    }

    @Test("reads a value that lives in a compacted table")
    func compacted() throws {
        #expect(try cleanValue(try RegistryFixtures.dir("compacted"), key).contains("compacted"))
    }

    @Test("prefers the newer log write over the older compacted value")
    func superseded() throws {
        let value = try cleanValue(try RegistryFixtures.dir("superseded"), key)
        #expect(value.contains("fresh"))
        #expect(!value.contains("stale"))
    }

    @Test("returns nil when the newest record is a deletion")
    func deletion() throws {
        let result = try LevelDBReader.readValue(directory: try RegistryFixtures.dir("deleted").path, userKey: key)
        #expect(result.value == nil)
    }

    @Test("returns nil for a key that was never written")
    func absent() throws {
        let result = try LevelDBReader.readValue(directory: try RegistryFixtures.dir("compacted").path, userKey: Array("_missing".utf8))
        #expect(result.value == nil)
    }

    @Test("rejects a directory that does not exist")
    func missingDirectory() throws {
        #expect(throws: (any Error).self) {
            try LevelDBReader.readValue(directory: "/nope/not/here", userKey: key)
        }
    }

    @Test("throws, rather than returning nil, when every file that could hold the key fails to parse")
    func allCorrupt() throws {
        let dir = try onlyTable("compacted", corrupt: true)
        var caught: (any Error)?
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        } catch {
            caught = error
        }
        // Names how many files were skipped: a parse failure must route to
        // "keep last known-good hosts", not to the "key absent" nil.
        let error = try #require(caught as? LevelDBReadError)
        #expect(error.message.contains("1 of 1"))
        #expect(error.cause != nil)
    }

    @Test("still returns the good record when a sibling file is corrupt")
    func corruptSibling() throws {
        // The corrupted file is the .ldb holding the stale value; the .log's
        // fresh value must still win.
        let dir = try copyFixture("superseded", corrupting: ".ldb")
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        #expect(try text(result.value).contains("fresh"))
        #expect(try #require(result.parseFailure).contains("1 of 2"))
    }

    @Test("reports the damage when the torn file was the one holding the newest value")
    func tornNewestFile() throws {
        // The `.log` held `fresh`; only `stale` survives. Returning it is
        // right; returning it silently is what let a deleted host linger.
        let dir = try copyFixture("superseded", corrupting: ".log", at: 8)
        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        #expect(try text(result.value).contains("stale"))
        #expect(try #require(result.parseFailure).contains("1 of 2"))
        #expect(try #require(result.parseFailure).contains("out of date"))
    }

    @Test("treats a deletion found next to an unreadable file as undetermined, not as an absent key")
    func deletionNextToDamage() throws {
        let dir = try copyFixture("deleted", corrupting: ".ldb")
        #expect(throws: LevelDBReadError.self) {
            try LevelDBReader.readValue(directory: dir.path, userKey: key)
        }
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key)
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
        }
    }

    @Test("scans a table named with the legacy .sst extension")
    func legacyExtension() throws {
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-sst")
        let source = try RegistryFixtures.dir("compacted")
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: dir.appendingPathComponent("000005.sst"))
        #expect(try cleanValue(dir, key).contains("compacted"))
    }

    @Test("propagates an unsupported compression type instead of treating it as a skippable parse failure")
    func unsupportedCompression() throws {
        // Rewrite the index block's compression byte and re-checksum, so the
        // block parses cleanly enough to reach the compression switch.
        let dir = try RegistryFixtures.temporaryDirectory("leveldb-reader-codec")
        let source = try RegistryFixtures.dir("compacted")
        let file = try #require(try RegistryFixtures.names(in: source, suffix: ".ldb").first)
        var bytes = [UInt8](try Data(contentsOf: source.appendingPathComponent(file)))
        let footer = Array(bytes[(bytes.count - 48)...])
        var pos = try Binary.readVarint64(footer, at: 0).next
        pos = try Binary.readVarint64(footer, at: pos).next
        let indexOffset = try Binary.readVarint64(footer, at: pos)
        let indexSize = try Binary.readVarint64(footer, at: indexOffset.next)
        let compressionByte = Int(indexOffset.value + indexSize.value)
        bytes[compressionByte] = 99
        let masked = Binary.maskCrc(Binary.crc32c(bytes[Int(indexOffset.value)...compressionByte]))
        for i in 0..<4 { bytes[compressionByte + 1 + i] = UInt8((masked >> (8 * UInt32(i))) & 0xff) }
        try Data(bytes).write(to: dir.appendingPathComponent(file))

        #expect(throws: SSTableError.unsupportedCompression(99)) {
            try LevelDBReader.readValue(directory: dir.path, userKey: key)
        }
    }

    @Test("reports the key as undetermined, not absent, when the only relevant file keeps vanishing")
    func alwaysVanishes() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish])

        // The listing named a file that could hold the key and we never got to
        // read it. "Absent" would send the tray to zero hosts.
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
            Issue.record("expected readValue to throw")
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
        }
        #expect(fs.readCounts[target] == LevelDBReader.maxScans)
    }

    @Test("returns the good record with a warning when a sibling file keeps vanishing")
    func siblingVanishes() throws {
        let dir = try copyFixture("superseded")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish])

        let result = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
        #expect(try text(result.value).contains("fresh"))
        #expect(try #require(result.parseFailure).contains("out of date"))
    }

    @Test("lists again when the newer file vanished, instead of returning the older survivor as current")
    func relistsAfterVanish() throws {
        // The .log holds `fresh`, the .ldb holds `stale`. The .log vanishes on
        // the first read only: a reader that only re-lists when it found
        // nothing would hand back `stale` with no signal.
        let dir = try copyFixture("superseded")
        let logPath = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".log").first)).path
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: logPath)))
        let fs = FakeFileSystem()
        fs.queue(logPath, [.vanish, .bytes(good)])

        #expect(try cleanValue(dir, key, fileSystem: fs).contains("fresh"))
    }

    @Test("treats a read error other than ENOENT as damage, not as a vanished file")
    func permissionDenied() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let fs = FakeFileSystem()
        fs.queue(target, [.fail(PermissionDenied())])

        // A file we were refused says nothing about where its data went.
        do {
            _ = try LevelDBReader.readValue(directory: dir.path, userKey: key, fileSystem: fs)
            Issue.record("expected readValue to throw")
        } catch let error as LevelDBReadError {
            #expect(error.message.contains("could not be determined"))
            #expect(errorText(try #require(error.cause)).contains("EACCES"))
        }
        // Damage is not a stale listing, so it must not trigger a re-list.
        #expect(fs.readCounts[target] == 1)
    }

    @Test("finds the record on the retried scan after the first scan saw the file vanish")
    func retrySucceeds() throws {
        let dir = try onlyTable("compacted")
        let target = dir.appendingPathComponent(try #require(try RegistryFixtures.names(in: dir, suffix: ".ldb").first)).path
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: target)))
        let fs = FakeFileSystem()
        fs.queue(target, [.vanish, .bytes(good)])

        #expect(try cleanValue(dir, key, fileSystem: fs).contains("compacted"))
        #expect(fs.readCounts[target] == 2)
    }
}

/// `LocalFileSystem` is the one place a real OS error becomes the
/// `notFound`-versus-damage distinction the re-list rule depends on. Every
/// other test injects `FileReadError` directly and never exercises it.
struct LocalFileSystemTests {
    @Test("maps a genuinely missing file to notFound")
    func missingFile() throws {
        let dir = try RegistryFixtures.temporaryDirectory("filesystem")
        let missing = dir.appendingPathComponent("gone.ldb").path
        do {
            _ = try LocalFileSystem().readFile(missing)
            Issue.record("expected readFile to throw")
        } catch let error as FileReadError {
            guard case .notFound = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
        }
    }

    @Test("maps a file it cannot read to damage, not to a vanished file")
    func unreadableFile() throws {
        let dir = try RegistryFixtures.temporaryDirectory("filesystem")
        let unreadable = dir.appendingPathComponent("locked.ldb")
        try Data("x".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        do {
            _ = try LocalFileSystem().readFile(unreadable.path)
            // Running as root defeats the permission bits; skip rather than
            // assert something the environment made untrue.
            return
        } catch let error as FileReadError {
            // Calling this "vanished" is how a permission problem turned into
            // an applied empty host set.
            guard case .other = error else {
                Issue.record("expected other, got \(error)")
                return
            }
        }
    }
}
