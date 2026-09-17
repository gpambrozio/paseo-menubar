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
}
