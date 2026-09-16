import Foundation

public enum TransportFrame: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
}

public struct TransportClose: Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct TransportRequest: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let subprotocols: [String]

    public init(url: URL, headers: [String: String] = [:], subprotocols: [String] = []) {
        self.url = url
        self.headers = headers
        self.subprotocols = subprotocols
    }
}

/// One WebSocket-shaped connection. `URLSessionWebSocketTransport` is the real
/// one; `E2EEChannel` wraps another transport and is one itself, which is how
/// the session stays unaware of whether a host is direct or relayed. Every
/// callback fires on the main actor.
@MainActor
public protocol DaemonTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onFrame: ((TransportFrame) -> Void)? { get set }
    var onClose: ((TransportClose) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect()
    func send(_ frame: TransportFrame)
    func close(code: Int, reason: String)
}

public typealias TransportFactory = @MainActor (TransportRequest) -> any DaemonTransport
