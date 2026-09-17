import Foundation

/// Where a click should send the user. Returned as a URL rather than opened
/// here, so the decision is pure and the app layer owns `NSWorkspace`.
public enum OpenTarget: Equatable, Sendable {
    case url(URL)
}

public struct OpenAgentTarget: Equatable, Sendable {
    public let serverId: String
    public let agentId: String
    /// Daemon HTTP base URL, used only when the desktop app is not installed.
    public let webBaseUrl: String?

    public init(serverId: String, agentId: String, webBaseUrl: String? = nil) {
        self.serverId = serverId
        self.agentId = agentId
        self.webBaseUrl = webBaseUrl
    }
}

public struct OpenWorkspaceTarget: Equatable, Sendable {
    /// Nil until the host's `server_info` has arrived. Optional here rather
    /// than guarded at the call site, so the "we cannot build a link yet" case
    /// sits beside the two fallbacks it is a sibling of, under test.
    public let serverId: String?
    public let workspaceId: String
    /// The workspace's most relevant agent, chosen by the view model, or nil.
    public let agentId: String?
    /// Daemon HTTP base URL. Direct hosts have one; relay hosts do not.
    public let webBaseUrl: String?

    public init(serverId: String?, workspaceId: String, agentId: String?, webBaseUrl: String? = nil) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.agentId = agentId
        self.webBaseUrl = webBaseUrl
    }
}

public enum OpenPaseo {
    /// The bare app link. macOS activates whichever app handles a scheme when
    /// a URL in it is opened, so this brings Paseo forward even though the
    /// desktop app's handler ignores links it cannot parse as an agent.
    public static let appDeepLink = URL(string: "paseo://")!

    /// The install-path probe the Paseo CLI uses for `paseo open`.
    public static func defaultDesktopAppInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/Paseo.app",
            home.appendingPathComponent("Applications/Paseo.app").path,
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// `/h/<serverId>/agent/<agentId>`, percent-encoded so an odd id cannot
    /// break the route. Copied from `buildAgentDeepLinkRoute` upstream.
    public static func agentRoute(serverId: String, agentId: String) -> String {
        "/h/\(encode(serverId))/agent/\(encode(agentId))"
    }

    public static func agentDeepLink(serverId: String, agentId: String) -> URL {
        URL(string: "paseo:/\(agentRoute(serverId: serverId, agentId: agentId))") ?? appDeepLink
    }

    /// Opens Paseo itself, with the same web fallback rule `agent` uses.
    public static func app(webBaseUrl: String?, desktopAppInstalled: Bool) -> OpenTarget {
        if !desktopAppInstalled, let webBaseUrl, let url = URL(string: trimSlashes(webBaseUrl)) {
            return .url(url)
        }
        return .url(appDeepLink)
    }

    public static func agent(_ target: OpenAgentTarget, desktopAppInstalled: Bool) -> OpenTarget {
        if !desktopAppInstalled, let webBaseUrl = target.webBaseUrl,
           let url = URL(string: trimSlashes(webBaseUrl) + agentRoute(serverId: target.serverId, agentId: target.agentId)) {
            return .url(url)
        }
        return .url(agentDeepLink(serverId: target.serverId, agentId: target.agentId))
    }

    /// Opens a workspace. There is no workspace deep link: the desktop app's
    /// handler drops what it cannot parse as an agent, so
    /// `paseo://h/<serverId>/workspace/<id>` opens nothing at all. Paseo is a
    /// separate repository and this app cannot change that, so a workspace is
    /// opened through one of its agents.
    public static func workspace(_ target: OpenWorkspaceTarget, desktopAppInstalled: Bool) -> OpenTarget {
        // No `server_info` yet, so there is nothing to build either link out of.
        // Opening Paseo itself beats swallowing the click.
        guard let serverId = target.serverId else {
            return app(webBaseUrl: target.webBaseUrl, desktopAppInstalled: desktopAppInstalled)
        }

        if let agentId = target.agentId {
            return agent(
                OpenAgentTarget(serverId: serverId, agentId: agentId, webBaseUrl: target.webBaseUrl),
                desktopAppInstalled: desktopAppInstalled
            )
        }

        // No agent to stand in for the workspace. The daemon's own web UI does
        // route this path, so the browser lands on the right workspace,
        // preferred over `paseo://` even with the desktop app installed, which
        // would only bring Paseo forward at whatever it happened to be showing.
        if let webBaseUrl = target.webBaseUrl,
           let url = URL(string: trimSlashes(webBaseUrl) + "/h/\(encode(serverId))/workspace/\(encode(target.workspaceId))") {
            return .url(url)
        }

        // A relay host with no agent in the workspace: no deep link, and no
        // HTTP origin to fall back to. Open Paseo itself rather than swallowing
        // the click, because a menu row that does nothing reads as a broken app.
        return app(webBaseUrl: nil, desktopAppInstalled: desktopAppInstalled)
    }

    /// Matches JavaScript's `encodeURIComponent`, which escapes `/` and space
    /// but leaves `-._~!*'()` alone.
    private static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func trimSlashes(_ url: String) -> String {
        var trimmed = url
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
