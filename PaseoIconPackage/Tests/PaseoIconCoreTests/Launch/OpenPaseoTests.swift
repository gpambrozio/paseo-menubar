import Foundation
import Testing
@testable import PaseoIconCore

struct OpenPaseoTests {
    private func url(_ target: OpenTarget) -> String {
        if case .url(let url) = target { return url.absoluteString }
        return ""
    }

    @Test("uses the paseo deep link for an agent when the desktop app is installed")
    func agentDeepLink() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv-1", agentId: "a1"), desktopAppInstalled: true)
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("falls back to the daemon web UI when the desktop app is absent")
    func agentWebFallback() {
        let target = OpenPaseo.agent(
            OpenAgentTarget(serverId: "srv-1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/agent/a1")
    }

    @Test("still tries the deep link when no web fallback is known")
    func agentNoFallback() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv-1", agentId: "a1"), desktopAppInstalled: false)
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("percent-encodes ids so an odd serverId cannot break the route")
    func encodesIds() {
        let target = OpenPaseo.agent(OpenAgentTarget(serverId: "srv 1", agentId: "a/1"), desktopAppInstalled: true)
        #expect(url(target) == "paseo://h/srv%201/agent/a%2F1")
    }

    @Test("probes real filesystem paths without trapping")
    func probe() {
        _ = OpenPaseo.defaultDesktopAppInstalled()
    }

    @Test("opens the workspace's agent, because there is no workspace deep link")
    func workspaceViaAgent() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: "a1"),
            desktopAppInstalled: true
        )
        #expect(url(target) == "paseo://h/srv-1/agent/a1")
    }

    @Test("falls back to the daemon's workspace route when the workspace has no agent")
    func workspaceWebRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: nil, webBaseUrl: "http://127.0.0.1:6767/"),
            desktopAppInstalled: true
        )
        // Even with the desktop app installed: `paseo://h/srv-1/workspace/w1`
        // parses as nothing and would open a window on some other screen.
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/workspace/w1")
    }

    @Test("percent-encodes ids in the workspace route")
    func encodesWorkspaceRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv 1", workspaceId: "w/1", agentId: nil, webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv%201/workspace/w%2F1")
    }

    @Test("opens Paseo itself when there is neither an agent nor a web URL")
    func workspaceNoTarget() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: nil),
            desktopAppInstalled: true
        )
        // A relay host with no agents. Doing nothing would read as a broken menu.
        #expect(url(target) == "paseo://")
    }

    @Test("uses the agent's web route when the desktop app is absent")
    func workspaceAgentWebRoute() {
        let target = OpenPaseo.workspace(
            OpenWorkspaceTarget(serverId: "srv-1", workspaceId: "w1", agentId: "a1", webBaseUrl: "http://127.0.0.1:6767"),
            desktopAppInstalled: false
        )
        #expect(url(target) == "http://127.0.0.1:6767/h/srv-1/agent/a1")
    }

    @Test("opens the app's scheme when the desktop app is installed")
    func appInstalled() {
        #expect(url(OpenPaseo.app(webBaseUrl: nil, desktopAppInstalled: true)) == "paseo://")
    }

    @Test("falls back to the daemon web UI for the app when the desktop app is absent")
    func appWebFallback() {
        #expect(url(OpenPaseo.app(webBaseUrl: "http://127.0.0.1:6767/", desktopAppInstalled: false)) == "http://127.0.0.1:6767")
    }

    @Test("still tries the scheme when no web fallback is known")
    func appNoFallback() {
        #expect(url(OpenPaseo.app(webBaseUrl: nil, desktopAppInstalled: false)) == "paseo://")
    }
    @Test("the bare scheme URL parses, so the first click cannot be the first failure")
    func appDeepLinkParses() {
        // `appDeepLink` is a lazily-evaluated global built with a force unwrap.
        // It parses on every Foundation shipped so far, but nothing pinned it —
        // so a parser change would trap at the user's first click on Open Paseo
        // rather than here.
        #expect(OpenPaseo.appDeepLink.absoluteString == "paseo://")
    }

    @Test("a workspace with no serverId yet opens Paseo rather than nothing")
    func workspaceWithoutServerId() {
        // Before `server_info` arrives there is no id to build either link out
        // of. This decision used to live in the app layer, where no test could
        // reach it; it belongs beside the other two fallbacks.
        let noWeb = OpenWorkspaceTarget(serverId: nil, workspaceId: "w1", agentId: "a1", webBaseUrl: nil)
        #expect(url(OpenPaseo.workspace(noWeb, desktopAppInstalled: true)) == "paseo://")

        // The fallback uses a *connected* host's origin, never this host's: no
        // serverId means no handshake, so its own origin cannot load, and
        // preferring it would suppress `paseo://` for a browser tab that fails.
        let ownUrlOnly = OpenWorkspaceTarget(
            serverId: nil, workspaceId: "w1", agentId: "a1",
            webBaseUrl: "http://10.0.0.9:6767/", fallbackWebBaseUrl: nil
        )
        #expect(url(OpenPaseo.workspace(ownUrlOnly, desktopAppInstalled: false)) == "paseo://")

        let withFallback = OpenWorkspaceTarget(
            serverId: nil, workspaceId: "w1", agentId: "a1",
            webBaseUrl: "http://10.0.0.9:6767/", fallbackWebBaseUrl: "http://127.0.0.1:6767/"
        )
        #expect(url(OpenPaseo.workspace(withFallback, desktopAppInstalled: false)) == "http://127.0.0.1:6767")
    }

}
