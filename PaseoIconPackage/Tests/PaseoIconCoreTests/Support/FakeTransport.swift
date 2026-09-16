import Foundation
@testable import PaseoIconCore

/// A transport the test drives by hand. Records what the code under test sent
/// and lets the test play the server's side.
@MainActor
final class FakeTransport: DaemonTransport {
    var onOpen: (() -> Void)?
    var onFrame: ((TransportFrame) -> Void)?
    var onClose: ((TransportClose) -> Void)?
    var onError: ((String) -> Void)?

    let request: TransportRequest
    private(set) var connectCalls = 0
    private(set) var sent: [TransportFrame] = []
    private(set) var closedWith: TransportClose?

    init(request: TransportRequest) {
        self.request = request
    }

    var sentText: [String] {
        sent.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    var sentBinary: [[UInt8]] {
        sent.compactMap { if case .binary(let bytes) = $0 { bytes } else { nil } }
    }

    func connect() { connectCalls += 1 }
    func send(_ frame: TransportFrame) { sent.append(frame) }
    func close(code: Int, reason: String) {
        guard closedWith == nil else { return }
        closedWith = TransportClose(code: code, reason: reason)
    }

    func clearSent() { sent = [] }
    func simulateOpen() { onOpen?() }
    func simulateText(_ text: String) { onFrame?(.text(text)) }
    func simulateBinary(_ bytes: [UInt8]) { onFrame?(.binary(bytes)) }
    func simulateClose(code: Int, reason: String) { onClose?(TransportClose(code: code, reason: reason)) }
}

@MainActor
final class FakeTransportFactory {
    private(set) var transports: [FakeTransport] = []

    func make(_ request: TransportRequest) -> any DaemonTransport {
        let transport = FakeTransport(request: request)
        transports.append(transport)
        return transport
    }

    var last: FakeTransport? { transports.last }
}

/// Lets tasks the code under test spawned run to their next suspension point.
/// Needed before advancing a `TestClock`, because a sleep only registers with
/// the clock once its task has started.
@MainActor
func settle() async {
    for _ in 0..<25 { await Task.yield() }
}

func jsonObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw NSError(domain: "FakeTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object: \(text)"])
    }
    return object
}
