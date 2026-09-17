import Foundation

/// `DaemonTransport` over `URLSessionWebSocketTask`. The password rides as
/// both an `Authorization: Bearer` header and a `paseo.bearer.<password>`
/// subprotocol, which is what the daemon reads; the daemon echoes the selected
/// subprotocol so the handshake completes.
@MainActor
public final class URLSessionWebSocketTransport: DaemonTransport {
    public var onOpen: (() -> Void)?
    public var onFrame: ((TransportFrame) -> Void)?
    public var onClose: ((TransportClose) -> Void)?
    public var onError: ((String) -> Void)?

    private let request: TransportRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// The tail of the send chain, so frames keep their order.
    private var sendTail: Task<Void, Never> = Task {}
    private var closed = false

    public init(request: TransportRequest) {
        self.request = request
    }

    public func connect() {
        // A second connect has to leave nothing of the first behind. Without
        // this, `closed` stayed true from the previous `close()` — so `send`
        // refused every frame forever — while the old `URLSession` and its
        // strongly-retained delegate leaked with the socket still open. A
        // silently dead channel. Production builds a fresh transport per
        // attempt, but the type should not punish a caller who does not.
        receiveTask?.cancel()
        sendTail.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        closed = false

        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.subprotocols.isEmpty {
            urlRequest.setValue(request.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let delegate = Delegate(
            onOpen: { [weak self] in
                Task { @MainActor in self?.onOpen?() }
            },
            onClose: { [weak self] code, reason in
                Task { @MainActor in self?.finish(code: code, reason: reason) }
            }
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: urlRequest)
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    /// Frames go out in the order they were handed over. `URLSessionWebSocketTask.send`
    /// is async, and one unstructured `Task` per frame does not preserve
    /// order: two sends can complete in either order, which on this wire would
    /// let a `fetch_agents_request` overtake the `hello` that has to precede
    /// it. Each send therefore awaits the previous one.
    public func send(_ frame: TransportFrame) {
        guard let task, !closed else {
            onError?("Transport not connected")
            return
        }
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .text(let text): message = .string(text)
        case .binary(let bytes): message = .data(Data(bytes))
        }
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous.value
            do {
                try await task.send(message)
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    public func close(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        sendTail.cancel()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
        session?.finishTasksAndInvalidate()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): onFrame?(.text(text))
                case .data(let data): onFrame?(.binary([UInt8](data)))
                @unknown default: break
                }
            } catch {
                handleReceiveFailure(error, task: task)
                return
            }
        }
    }

    /// `receive()` throws when the socket ends for any reason. If the server
    /// sent a close frame, the task already carries its code and reason; a
    /// dropped connection or a failed handshake carries neither and reports
    /// as 1006 with the error text.
    private func handleReceiveFailure(_ error: any Error, task: URLSessionWebSocketTask) {
        guard !closed else { return }
        onError?(error.localizedDescription)
        let closeCode = task.closeCode
        if closeCode == .invalid {
            finish(code: 1006, reason: error.localizedDescription)
        } else {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            finish(code: closeCode.rawValue, reason: reason)
        }
    }

    private func finish(code: Int, reason: String) {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        session?.invalidateAndCancel()
        onClose?(TransportClose(code: code, reason: reason))
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let openHandler: @Sendable () -> Void
        private let closeHandler: @Sendable (Int, String) -> Void

        init(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Int, String) -> Void) {
            self.openHandler = onOpen
            self.closeHandler = onClose
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            openHandler()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            closeHandler(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }
}
