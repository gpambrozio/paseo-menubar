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
    /// Which socket the callbacks belong to. A cancelled receive loop and an
    /// invalidated session's delegate both keep running for a moment after
    /// `connect()` has replaced them, and both end in code that closes "the"
    /// socket. Without a generation to check, the predecessor tears down its
    /// successor. Incremented on every `connect()`.
    private var generation = 0

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
        generation += 1
        // A fresh chain, not the cancelled predecessor: the first send after a
        // reconnect would otherwise await a cancelled task, and the old chain's
        // cancellation would surface through the new transport's `onError`.
        sendTail = Task {}

        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.subprotocols.isEmpty {
            urlRequest.setValue(request.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let generation = self.generation
        let delegate = Delegate(
            onOpen: { [weak self] in
                Task { @MainActor in self?.deliverOpen(generation: generation) }
            },
            onClose: { [weak self] code, reason in
                Task { @MainActor in self?.finish(code: code, reason: reason, generation: generation) }
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
        // `task === self.task` is the whole point: a receive loop cancelled by
        // `connect()` still throws and still lands here, and by then `closed`
        // has been reset, so the guard below passes and the predecessor closes
        // the socket its successor just opened — reporting a close the owner
        // never caused.
        guard !closed, task === self.task else { return }
        onError?(error.localizedDescription)
        let closeCode = task.closeCode
        if closeCode == .invalid {
            finish(code: 1006, reason: error.localizedDescription)
        } else {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            finish(code: closeCode.rawValue, reason: reason)
        }
    }

    private func deliverOpen(generation: Int) {
        guard generation == self.generation else { return }
        onOpen?()
    }

    private func finish(code: Int, reason: String, generation: Int? = nil) {
        // An invalidated session's delegate is retained by that session and has
        // no notion of which socket it belongs to, so a late `didCloseWith`
        // from the previous generation must not close the current one.
        if let generation, generation != self.generation { return }
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
