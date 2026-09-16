import Foundation
import Testing
@testable import PaseoIconCore

/// Against `scripts/swift-test-ws-echo.mjs`, a `ws` server that reports the
/// handshake it saw, echoes frames, and closes with 4401 on request.
@MainActor
struct URLSessionWebSocketTransportTests {
    @MainActor
    final class Recorder {
        var opened = false
        var frames: [TransportFrame] = []
        var close: TransportClose?
        var errors: [String] = []
    }

    @Test("sends the bearer header and subprotocol, echoes text and binary, and surfaces the close reason")
    func roundTrip() async throws {
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(
            url: URL(string: "ws://127.0.0.1:\(port)/")!,
            headers: ["Authorization": "Bearer s3cret"],
            subprotocols: ["paseo.bearer.s3cret"]
        ))
        let recorder = Recorder()
        transport.onOpen = { recorder.opened = true }
        transport.onFrame = { recorder.frames.append($0) }
        transport.onClose = { recorder.close = $0 }
        transport.onError = { recorder.errors.append($0) }
        transport.connect()

        #expect(await eventually { recorder.opened && recorder.frames.count == 1 })
        guard case .text(let handshake)? = recorder.frames.first else {
            Issue.record("expected the handshake report")
            return
        }
        let report = try jsonObject(handshake)
        #expect(report["protocol"] as? String == "paseo.bearer.s3cret")
        #expect(report["authorization"] as? String == "Bearer s3cret")

        transport.send(.text("hello"))
        transport.send(.binary([1, 2, 3]))
        #expect(await eventually { recorder.frames.count == 3 })
        #expect(recorder.frames[1] == .text("hello"))
        #expect(recorder.frames[2] == .binary([1, 2, 3]))

        transport.send(.text("close-me"))
        #expect(await eventually { recorder.close != nil })
        #expect(recorder.close == TransportClose(code: 4401, reason: "Incorrect password"))
    }

    @Test("keeps frames in the order they were handed over, under load")
    func sendOrder() async throws {
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        let recorder = Recorder()
        transport.onOpen = { recorder.opened = true }
        transport.onFrame = { recorder.frames.append($0) }
        transport.connect()
        #expect(await eventually { recorder.opened && recorder.frames.count == 1 })

        // One unstructured Task per frame does not preserve order: this fails
        // without the send chain, reliably at this count, and intermittently
        // at two frames under a busy machine.
        let sent = (0..<40).map { "frame-\($0)" }
        for text in sent { transport.send(.text(text)) }

        #expect(await eventually { recorder.frames.count == sent.count + 1 })
        let echoed = recorder.frames.dropFirst().compactMap { frame -> String? in
            if case .text(let text) = frame { return text }
            return nil
        }
        #expect(echoed == sent)
    }

    @Test("a refused connection closes with 1006 and an error")
    func refused() async throws {
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:1/")!))
        let recorder = Recorder()
        transport.onClose = { recorder.close = $0 }
        transport.onError = { recorder.errors.append($0) }
        transport.connect()
        #expect(await eventually { recorder.close != nil })
        #expect(recorder.close?.code == 1006)
        #expect(!recorder.errors.isEmpty)
    }
}
