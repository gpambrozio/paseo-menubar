import Foundation
import Testing

/// Runs one of the `scripts/swift-test-*.mjs` harnesses with `node`, reads the
/// JSON line it prints once ready, and stops it by closing its stdin.
final class NodeHarness: @unchecked Sendable {
    let info: [String: Any]
    private let process: Process
    private let stdin: Pipe

    /// The repository root: this file is `PaseoIconPackage/Tests/PaseoIconCoreTests/Support/NodeHarness.swift`.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // PaseoIconCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PaseoIconPackage
            .deletingLastPathComponent()  // repo root
    }

    init(script: String, arguments: [String] = []) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", Self.repoRoot.appendingPathComponent("scripts/\(script)").path] + arguments
        process.currentDirectoryURL = Self.repoRoot
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.stdin = stdin

        var firstLine: String?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            firstLine = line
            break
        }
        guard let firstLine, let data = firstLine.data(using: .utf8),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            process.terminate()
            throw NSError(domain: "NodeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(script) printed no JSON line"])
        }
        self.info = info
    }

    func int(_ key: String) throws -> Int { try #require(info[key] as? Int) }
    func string(_ key: String) throws -> String { try #require(info[key] as? String) }

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Polls a condition in real time; for tests against real processes only.
@MainActor
func eventually(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await clock.sleep(for: .milliseconds(25))
    }
    return condition()
}
