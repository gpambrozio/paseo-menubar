/// One host the tray dials. The shapes mirror `@getpaseo/protocol` 0.4.0:
/// `DirectTcpHostConnectionSchema` for `directTcp` and `ConnectionOfferSchema`
/// for `relay`. `label` is the user's explicit name; nil lets the tray fall
/// through to the daemon's own `hostname`.
public enum HostEntry: Equatable, Sendable {
    case directTcp(id: String, label: String?, endpoint: String, useTls: Bool, password: String?)
    case relay(id: String, label: String?, offer: ConnectionOffer)

    public var id: String {
        switch self {
        case .directTcp(let id, _, _, _, _), .relay(let id, _, _): id
        }
    }

    public var label: String? {
        switch self {
        case .directTcp(_, let label, _, _, _), .relay(_, let label, _): label
        }
    }

    /// The last-resort display name: the network address the entry dials. A
    /// relay entry has no daemon-facing address before it connects, so the
    /// relay's own endpoint stands in.
    public var endpointHint: String {
        switch self {
        case .directTcp(_, _, let endpoint, _, _): endpoint
        case .relay(_, _, let offer): offer.relay.endpoint
        }
    }
}
