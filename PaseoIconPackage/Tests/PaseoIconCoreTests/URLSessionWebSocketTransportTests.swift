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
    @Test("a second connect survives its predecessor's teardown")
    func reconnectIsNotTornDownByThePreviousSocket() async throws {
        // `close()` then `connect()`. The old receive loop is still suspended
        // in `receive()`; cancelling it makes that throw, and the error path
        // used to close "the" socket unconditionally — which by then was the
        // new one. The owner got a socket that opened and died milliseconds
        // later, plus a `TransportClose` it never caused, which a session-shaped
        // owner answers with a reconnect.
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(
            url: URL(string: "ws://127.0.0.1:\(port)/")!,
            headers: [:],
            subprotocols: []
        ))
        let first = Recorder()
        transport.onOpen = { first.opened = true }
        transport.onFrame = { first.frames.append($0) }
        transport.onClose = { first.close = $0 }
        transport.onError = { first.errors.append($0) }
        transport.connect()
        #expect(await eventually { first.opened })

        // A client-initiated close reports nothing back, by design.
        transport.close(code: 1000, reason: "done")
        #expect(first.close == nil)

        // Second generation, with its own recorder so nothing from the first
        // can be mistaken for it.
        let second = Recorder()
        transport.onOpen = { second.opened = true }
        transport.onFrame = { second.frames.append($0) }
        transport.onClose = { second.close = $0 }
        transport.onError = { second.errors.append($0) }
        transport.connect()

        // It opens, and the handshake report arrives — so `send` is not refused
        // by a `closed` flag the predecessor set.
        #expect(await eventually { second.opened && !second.frames.isEmpty })
        transport.send(.text("hello"))
        #expect(await eventually { second.frames.count >= 2 })
        #expect(second.frames.contains(.text("hello")))
        // And nothing closed it behind the owner's back.
        #expect(second.close == nil)
    }

    @Test("a frame the old socket received is not delivered after close and reconnect")
    func staleFrameDoesNotReachTheNextConnection() async throws {
        // The receive loop resumes on the main actor. A frame that lands while
        // the main actor is busy has already completed its `receive()`, so
        // cancelling the loop cannot take it back: the loop wakes after
        // `close()` and `connect()` have run and hands the frame to whatever
        // `onFrame` is by then — the next connection's. On CI that was the
        // first socket's handshake report, arriving as the second's.
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        let first = Recorder()
        transport.onOpen = { first.opened = true }
        transport.onFrame = { first.frames.append($0) }
        transport.onClose = { first.close = $0 }
        transport.onError = { first.errors.append($0) }
        transport.connect()
        #expect(await eventually { first.opened && first.frames.count == 1 })

        // Ask for a frame 300 ms from now; the echo of "armed" says the
        // request was read. Then hold the main actor past the deadline, so the
        // frame arrives on a receive the loop cannot act on yet.
        transport.send(.text("later:300:stale"))
        transport.send(.text("armed"))
        #expect(await eventually { first.frames.contains(.text("armed")) })
        holdMainActor(seconds: 1)

        transport.close(code: 1000, reason: "done")
        let second = Recorder()
        transport.onOpen = { second.opened = true }
        transport.onFrame = { second.frames.append($0) }
        transport.onClose = { second.close = $0 }
        transport.onError = { second.errors.append($0) }
        transport.connect()

        #expect(await eventually { second.opened && !second.frames.isEmpty })
        transport.send(.text("hello"))
        #expect(await eventually { second.frames.contains(.text("hello")) })
        #expect(!second.frames.contains(.text("stale")))
        #expect(second.frames.count == 2)
        // A client-initiated close delivers nothing to the closed owner either.
        #expect(!first.frames.contains(.text("stale")))
        #expect(second.errors.isEmpty)
        #expect(second.close == nil)
    }

    @Test("a send the old socket could not finish reports no error, to its owner or the next")
    func staleSendErrorDoesNotReachTheNextConnection() async throws {
        // The send chain runs on the main actor, so these sends have not
        // started when `close()` cancels the socket under them. Each then fails
        // with "cancelled", and used to report it through `onError` — which by
        // then belonged to the next connection.
        let harness = try await NodeHarness(script: "swift-test-ws-echo.mjs")
        defer { harness.stop() }
        let port = try harness.int("port")
        let transport = URLSessionWebSocketTransport(request: TransportRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        let first = Recorder()
        transport.onOpen = { first.opened = true }
        transport.onFrame = { first.frames.append($0) }
        transport.onError = { first.errors.append($0) }
        transport.connect()
        #expect(await eventually { first.opened && first.frames.count == 1 })

        for index in 0..<10 { transport.send(.text("doomed-\(index)")) }
        transport.close(code: 1000, reason: "done")
        let second = Recorder()
        transport.onOpen = { second.opened = true }
        transport.onFrame = { second.frames.append($0) }
        transport.onClose = { second.close = $0 }
        transport.onError = { second.errors.append($0) }
        transport.connect()

        #expect(await eventually { second.opened && !second.frames.isEmpty })
        transport.send(.text("hello"))
        #expect(await eventually { second.frames.contains(.text("hello")) })
        #expect(second.errors.isEmpty)
        #expect(first.errors.isEmpty)
        #expect(second.close == nil)
    }

    /// Blocks rather than suspends: nothing else on the main actor runs meanwhile.
    private func holdMainActor(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
