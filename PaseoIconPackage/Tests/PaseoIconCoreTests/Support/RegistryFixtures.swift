import Foundation
import Testing
@testable import PaseoIconCore

/// The LevelDB directories `scripts/make-registry-fixtures.mjs` generates,
/// copied into the test bundle as-is.
enum RegistryFixtures {
    static let registryKey = LocalStorage.key(origin: "paseo://app", key: "@paseo:daemon-registry")

    static func dir(_ name: String) throws -> URL {
        let root = try #require(Bundle.module.resourceURL)
        return root.appendingPathComponent("Fixtures/registry/\(name)", isDirectory: true)
    }

    static func names(in dir: URL, suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// The one `.ldb` in a fixture, as bytes.
    static func tableBytes(_ name: String) throws -> [UInt8] {
        let dir = try dir(name)
        let names = try names(in: dir, suffix: ".ldb")
        #expect(names.count == 1, "expected one .ldb in \(name)")
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent(try #require(names.first))))
    }

    /// The first `.log` in a fixture, as bytes.
    static func logBytes(_ name: String) throws -> [UInt8] {
        let dir = try dir(name)
        let names = try names(in: dir, suffix: ".log")
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent(try #require(names.first))))
    }

    /// A value's text past Chromium's one-byte encoding tag, decoded as Latin1.
    static func latin1(_ value: [UInt8]) -> String {
        String(bytes: value.dropFirst(), encoding: .isoLatin1) ?? ""
    }

    /// Mirrors the generator's `fillerKey`: "0-key-*" sorts before the real
    /// registry key, "z-key-*" sorts after it.
    static func fillerKey(_ side: String, _ index: Int) -> [UInt8] {
        LocalStorage.key(origin: "paseo://app", key: "\(side)-key-\(String(format: "%04d", index))")
    }

    /// Mirrors the generator's `STRADDLE_KEY`.
    static let straddleKey = LocalStorage.key(origin: "paseo://app", key: "zz-straddle")

    /// A fresh temporary directory the test owns.
    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies every file of a fixture into `destination`.
    static func copy(_ name: String, into destination: URL) throws {
        let source = try dir(name)
        for file in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: destination.appendingPathComponent(file))
        }
    }
}
