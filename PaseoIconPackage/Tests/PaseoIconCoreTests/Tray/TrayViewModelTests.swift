import Foundation
import Testing
@testable import PaseoIconCore

struct TrayViewModelTests {
    private func build(_ hosts: [HostSnapshot], configError: String? = nil) -> TrayViewModel {
        TrayViewModelBuilder.build(hosts: hosts, configError: configError)
    }

    @Test("shows the Paseo mark when there are no workspaces at all")
    func emptyFleet() {
        let model = build([Fixture.host()])
        #expect(model.icon == .done)
        #expect(model.count == 0)
    }

    @Test("shows the done icon when everything is done, because done is the resting state")
    func allDone() {
        let model = build([Fixture.host([Fixture.workspace("w1"), Fixture.workspace("w2")])])
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.sections.map(\.bucket) == [.done])
    }

    @Test("shows the running icon when a workspace is running and nothing outranks it")
    func running() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "running")])])
        #expect(model.icon == .running)
        #expect(model.count == 0)
    }

    @Test("lets a counted bucket outrank running")
    func attentionOutranksRunning() {
        let model = build([Fixture.host([
            Fixture.workspace("w1", status: "running"),
            Fixture.workspace("w2", status: "attention"),
        ])])
        #expect(model.icon == .attention)
        #expect(model.count == 1)
    }

    @Test("counts needs_input, failed, and attention but never done or running")
    func countedBuckets() {
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "needs_input"),
            Fixture.workspace("b", status: "failed"),
            Fixture.workspace("c", status: "attention"),
            Fixture.workspace("d", status: "running"),
            Fixture.workspace("e", status: "done"),
        ])])
        #expect(model.count == 3)
        #expect(model.icon == .needsInput)
    }

    @Test("picks the icon of the highest-priority non-empty bucket in section order")
    func iconFollowsSectionOrder() {
        // failed, running, and done are all present; only failed outranks the
        // others in section order, so only the ordering rule can produce this.
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "done"),
            Fixture.workspace("b", status: "running"),
            Fixture.workspace("c", status: "failed"),
        ])])
        #expect(model.icon == .failed)
    }

    @Test("orders sections the way the Paseo sidebar does")
    func sectionOrder() {
        // All five buckets, supplied in an order matching none of them, so
        // every position is pinned. A section order that drifts from the
        // sidebar's defeats the whole point of listing workspaces.
        let model = build([Fixture.host([
            Fixture.workspace("e", status: "done"),
            Fixture.workspace("d", status: "running"),
            Fixture.workspace("c", status: "attention"),
            Fixture.workspace("b", status: "failed"),
            Fixture.workspace("a", status: "needs_input"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput, .failed, .attention, .running, .done])
    }

    @Test("omits sections with no workspaces in them")
    func omitsEmptySections() {
        let model = build([Fixture.host([
            Fixture.workspace("a", status: "needs_input"),
            Fixture.workspace("e", status: "done"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput, .done])
    }

    @Test("takes the bucket from the daemon rather than deriving one")
    func daemonOwnsTheBucket() {
        // The workspace's own agent is idle and wants nothing; the daemon
        // still says `needs_input`, and the daemon wins.
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input")], agents: [Fixture.agent("a1")])])
        #expect(model.sections.map(\.bucket) == [.needsInput])
        #expect(model.count == 1)
    }

    @Test("drops a workspace whose bucket this build has never heard of, rather than guessing")
    func unknownBucket() {
        // The daemon is not version-pinned. A bucket it adds tomorrow must
        // cost that row, not the menu, and must never be counted or iconed.
        let model = build([Fixture.host([
            Fixture.workspace("w1", status: "brand_new_bucket"),
            Fixture.workspace("w2", status: "needs_input"),
        ])])
        #expect(model.sections.map(\.bucket) == [.needsInput])
        #expect(model.count == 1)
    }

    @Test("excludes workspaces being archived from counts and rows")
    func excludesArchiving() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input", archivingAt: "2026-08-16T00:00:00.000Z")])])
        #expect(model.icon == .done)
        #expect(model.count == 0)
        #expect(model.sections.isEmpty)
    }

    @Test("excludes a disconnected host's workspaces from counts")
    func excludesDisconnected() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "needs_input")], status: .disconnected)])
        #expect(model.icon == .done)
        #expect(model.count == 0)
    }

    @Test("carries the workspace's own name and project, not a derived label")
    func rowContent() throws {
        let model = build([Fixture.host([Fixture.workspace("w1", name: "fix-login", projectDisplayName: "paseo-menubar")])])
        let row = try #require(model.sections.first?.rows.first)
        #expect(row.label == "fix-login")
        #expect(row.projectName == "paseo-menubar")
    }

    @Test("omits the host label with a single host and includes it with two")
    func hostLabelVisibility() {
        let single = build([Fixture.host([Fixture.workspace("w1")])])
        #expect(single.sections.first?.rows.first?.hostLabel == nil)

        let multiple = build([
            Fixture.host([Fixture.workspace("w1")]),
            Fixture.host(hostId: "h2", label: "studio", serverId: "srv-2"),
        ])
        #expect(multiple.sections.first?.rows.first?.hostLabel == "laptop")
    }

    @Test("caps rows in a section at 15 and reports the overflow")
    func sectionCap() throws {
        let many = (0..<18).map { Fixture.workspace("w\($0)", status: "needs_input") }
        let model = build([Fixture.host(many)])
        let section = try #require(model.sections.first { $0.bucket == .needsInput })
        #expect(section.rows.count == 15)
        #expect(section.overflow == 3)
        // The count is the whole bucket, not the visible slice.
        #expect(model.count == 18)
    }

    @Test("names hosts whose workspace list was capped so the rows are never a silent subset")
    func truncatedHosts() {
        let model = build([
            Fixture.host([Fixture.workspace("w1")], workspacesTruncated: true),
            Fixture.host(hostId: "h2", label: "studio"),
        ])
        #expect(model.truncatedHosts == ["laptop"])
    }

    @Test("names hosts whose agent page was capped, because their click targets may be missing")
    func agentTruncatedHosts() {
        let model = build([
            Fixture.host([Fixture.workspace("w1")], agentsTruncated: true),
            Fixture.host(hostId: "h2", label: "studio"),
        ])
        #expect(model.agentIndexTruncatedHosts == ["laptop"])
        #expect(model.truncatedHosts.isEmpty)
    }

    @Test("ignores truncation on a host whose workspaces are excluded anyway")
    func truncationOnDisconnected() {
        let model = build([Fixture.host(
            [Fixture.workspace("w1")],
            status: .disconnected,
            workspacesTruncated: true,
            agentsTruncated: true
        )])
        #expect(model.truncatedHosts.isEmpty)
        #expect(model.agentIndexTruncatedHosts.isEmpty)
    }

    @Test("reports host connection state for the status footer")
    func hostStatuses() {
        let model = build([
            Fixture.host(status: .connected),
            Fixture.host(hostId: "h2", label: "studio", status: .disconnected, serverId: nil),
        ])
        #expect(model.hostStatuses == [
            TrayHostStatus(hostId: "h1", label: "laptop", status: .connected),
            TrayHostStatus(hostId: "h2", label: "studio", status: .disconnected),
        ])
    }

    @Test("carries a configuration error through to the menu, keeping the last good hosts")
    func configError() {
        let model = build([Fixture.host([Fixture.workspace("w1", status: "failed")])], configError: "registry error\n\nnot valid JSON")
        #expect(model.configError == "registry error\n\nnot valid JSON")
        #expect(model.count == 1)
    }

    @Test("has no configuration error by default")
    func noConfigError() {
        #expect(build([Fixture.host()]).configError == nil)
    }

    @Test("carries serverId on rows so a click can build a deep link")
    func rowServerId() throws {
        let row = try #require(build([Fixture.host([Fixture.workspace("w1")])]).sections.first?.rows.first)
        #expect(row.serverId == "srv-1")
        #expect(row.workspaceId == "w1")
    }
}

struct ResolveHostNameTests {
    /// Every case supplies a distinct value at every tier, so a wrong
    /// precedence picks a different string rather than one that coincides.
    private func tiers(label: String? = "explicit-label", hostname: String? = "live-hostname", serverId: String? = "srv-id") -> String {
        resolveHostName(label: label, hostname: hostname, serverId: serverId, endpointHint: "127.0.0.1:6767")
    }

    @Test("prefers the explicit label over everything else")
    func prefersLabel() {
        #expect(tiers() == "explicit-label")
    }

    @Test("falls through the tiers in order")
    func fallsThrough() {
        #expect(tiers(label: nil) == "live-hostname")
        #expect(tiers(label: nil, hostname: nil) == "srv-id")
        #expect(tiers(label: nil, hostname: nil, serverId: nil) == "127.0.0.1:6767")
    }

    @Test("pins an explicit label even once a hostname arrives")
    func labelWins() {
        #expect(tiers(label: "Local", hostname: "build-box.local") == "Local")
    }

    @Test("drops the mDNS suffix a machine announces itself with")
    func dropsSuffix() {
        func shorten(_ hostname: String) -> String { tiers(label: nil, hostname: hostname) }
        #expect(shorten("build-box.local") == "build-box")
        #expect(shorten("build-box.localdomain") == "build-box")
        #expect(shorten("AI-MBP.LOCAL") == "AI-MBP")
        // A fully-qualified name may carry the DNS root dot.
        #expect(shorten("build-box.local.") == "build-box")
    }

    @Test("strips the suffix only at the end, and only as a whole label")
    func stripsPrecisely() {
        func shorten(_ hostname: String) -> String { tiers(label: nil, hostname: hostname) }
        // Not a suffix: the machine is simply named this.
        #expect(shorten("mylocal") == "mylocal")
        // Not at the end: a real domain that happens to contain the word.
        #expect(shorten("box.local.example.com") == "box.local.example.com")
        // `.localdomain` must win over `.local`, or the result keeps a stray `domain`.
        #expect(shorten("box.localdomain") == "box")
    }

    @Test("falls through rather than rendering an empty name")
    func neverEmpty() {
        #expect(tiers(label: nil, hostname: ".local") == "srv-id")
        #expect(tiers(label: nil, hostname: "") == "srv-id")
    }

    @Test("renders an explicit label verbatim, suffix and all")
    func labelVerbatim() {
        // A user who types `foo.local` means it; only the reported hostname is shortened.
        #expect(tiers(label: "foo.local") == "foo.local")
    }
}

struct TrayViewModelHostNamingTests {
    @Test("shows the live hostname in the host status line when the entry has no label")
    func liveHostname() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(label: nil, hostname: "build-box.local", serverId: "srv_example")])
        #expect(model.hostStatuses == [TrayHostStatus(hostId: "h1", label: "build-box", status: .connected)])
    }

    @Test("falls back to the serverId when the daemon reports no hostname")
    func serverIdFallback() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(label: nil, hostname: nil, serverId: "srv_example")])
        #expect(model.hostStatuses.first?.label == "srv_example")
    }

    @Test("uses the resolved name, not the raw label, for a truncated-host line")
    func truncatedUsesResolved() {
        let model = TrayViewModelBuilder.build(hosts: [Fixture.host(
            [Fixture.workspace("w1")],
            label: nil,
            hostname: "build-box.local",
            workspacesTruncated: true
        )])
        #expect(model.truncatedHosts == ["build-box"])
    }

    @Test("uses the resolved name for the per-row host label with more than one host")
    func rowUsesResolved() {
        let model = TrayViewModelBuilder.build(hosts: [
            Fixture.host([Fixture.workspace("w1")], label: nil, hostname: "build-box.local"),
            Fixture.host(hostId: "h2", label: "studio", serverId: "srv-2"),
        ])
        #expect(model.sections.first?.rows.first?.hostLabel == "build-box")
    }
}

struct TrayViewModelClickTargetTests {
    private func row(_ host: HostSnapshot) -> TrayWorkspaceRow? {
        TrayViewModelBuilder.build(hosts: [host]).sections.first?.rows.first
    }

    @Test("opens the workspace's only agent")
    func onlyAgent() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: [Fixture.agent("a1")]))?.agentId == "a1")
    }

    @Test("has no target when the workspace has no agent")
    func noAgent() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: []))?.agentId == nil)
    }

    @Test("ignores agents belonging to another workspace")
    func otherWorkspace() {
        #expect(row(Fixture.host([Fixture.workspace("w1")], agents: [Fixture.agent("a1", workspaceId: "w2")]))?.agentId == nil)
    }

    // Every case below is arranged so the tiebreakers would pick a different
    // agent than the rule under test.
    @Test("picks the most urgent agent by the daemon's own status priority")
    func statusPriority() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-idle", status: "idle", updatedAt: "2026-08-16T03:00:00.000Z"),
            Fixture.agent("b-running", status: "running", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-errored", status: "error", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        // Last by id and oldest by updatedAt, so only priority can put it first.
        #expect(target?.agentId == "z-errored")
    }

    @Test("ranks a pending permission above an error")
    func permissionOutranksError() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-errored", status: "error", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-asking", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z", attentionReason: "permission", pendingPermissions: 1),
        ]))
        #expect(target?.agentId == "z-asking")
    }

    @Test("counts a pending permission even when the attention reason says nothing")
    func pendingPermissionCount() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-errored", status: "error", updatedAt: "2026-08-16T02:00:00.000Z"),
            Fixture.agent("z-asking", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z", pendingPermissions: 2),
        ]))
        // The count alone is the first term of the daemon's ranking; dropping
        // the field would silently demote every agent waiting on a permission.
        #expect(target?.agentId == "z-asking")
    }

    @Test("breaks a priority tie on updatedAt, newest first, then on id")
    func tiebreakers() {
        let byTime = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("a-older", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("z-newer", status: "running", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        // Last by id, so only the timestamp can put it first.
        #expect(byTime?.agentId == "z-newer")

        let byId = row(Fixture.host([Fixture.workspace("w1")], agents: [
            Fixture.agent("b", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("a", status: "running", updatedAt: "2026-08-16T00:00:00.000Z"),
        ]))
        #expect(byId?.agentId == "a")
    }

    @Test("never targets an archived agent")
    func archivedAgent() {
        let target = row(Fixture.host([Fixture.workspace("w1")], agents: [
            // More urgent and newer, so only the archive filter can exclude it.
            Fixture.agent("gone", status: "error", updatedAt: "2026-08-16T02:00:00.000Z", archivedAt: "2026-08-16T00:00:00.000Z"),
            Fixture.agent("live", status: "idle", updatedAt: "2026-08-16T01:00:00.000Z"),
        ]))
        #expect(target?.agentId == "live")
    }
}
