import Foundation
import Testing
@testable import PaseoIconCore

struct MenuModelTests {
    private func row(workspaceId: String = "w1", agentId: String? = "a1", hostLabel: String? = nil) -> TrayWorkspaceRow {
        TrayWorkspaceRow(
            hostId: "h1",
            serverId: "srv-1",
            workspaceId: workspaceId,
            agentId: agentId,
            label: "fix-login",
            projectName: "paseo",
            hostLabel: hostLabel
        )
    }

    private func model(
        sections: [TrayMenuSection] = [],
        hostStatuses: [TrayHostStatus] = [],
        truncatedHosts: [String] = [],
        agentIndexTruncatedHosts: [String] = [],
        configError: String? = nil,
        unknownStates: [String: Int] = [:]
    ) -> TrayViewModel {
        TrayViewModel(
            icon: .done,
            count: 0,
            sections: sections,
            hostStatuses: hostStatuses,
            truncatedHosts: truncatedHosts,
            agentIndexTruncatedHosts: agentIndexTruncatedHosts,
            configError: configError,
            unknownStates: unknownStates
        )
    }

    private func build(_ model: TrayViewModel, loginItemEnabled: Bool = false, hostsExpanded: Bool = false) -> [MenuItem] {
        MenuModel.build(model, loginItemEnabled: loginItemEnabled, hostsExpanded: hostsExpanded)
    }

    private func hostRows(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .hostStatus(_, let label, _) = $0 { label } else { nil } }
    }

    private func summary(_ items: [MenuItem]) -> String? {
        items.compactMap { if case .hostsSummary(let label, _) = $0 { label } else { nil } }.first
    }

    private func notes(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .note(_, let text) = $0 { text } else { nil } }
    }

    private func headings(_ items: [MenuItem]) -> [String] {
        items.compactMap { if case .sectionHeading(_, let label) = $0 { label } else { nil } }
    }

    @Test("shows an explicit empty state")
    func emptyState() {
        #expect(notes(build(model())).contains("No workspaces"))
    }

    @Test("labels sections with Paseo's own words")
    func sectionLabels() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .failed, rows: [row(workspaceId: "w2")], overflow: 0),
            TrayMenuSection(bucket: .attention, rows: [row(workspaceId: "w3")], overflow: 0),
            TrayMenuSection(bucket: .running, rows: [row(workspaceId: "w4")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w5")], overflow: 0),
        ]))
        #expect(headings(items) == ["Needs input", "Failed", "Ready to review", "Working", "Done"])
    }

    @Test("gives each section heading its own bucket, so the icon layer cannot swap them")
    func headingCarriesBucket() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w2")], overflow: 0),
        ]))
        let buckets = items.compactMap { item -> WorkspaceStateBucket? in
            if case .sectionHeading(let bucket, _) = item { return bucket }
            return nil
        }
        #expect(buckets == [.needsInput, .done])
    }

    @Test("rules between sections, but never above the first one")
    func separators() {
        let items = build(model(sections: [
            TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0),
            TrayMenuSection(bucket: .running, rows: [row(workspaceId: "w2")], overflow: 0),
            TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w3")], overflow: 0),
        ]))
        // Shape down to the footer: heading, row, rule, heading, row, rule,
        // heading, row. A leading rule would show up in position 0.
        let shape = items.prefix(8).map { item -> String in
            switch item {
            case .separator: "---"
            case .sectionHeading(_, let label): label
            case .workspace(_, let label): label
            default: "?"
            }
        }
        #expect(shape == ["Needs input", "fix-login  ·  paseo", "---", "Working", "fix-login  ·  paseo", "---", "Done", "fix-login  ·  paseo"])
    }

    @Test("draws no rule when only one section has anything in it")
    func singleSection() {
        let items = build(model(sections: [TrayMenuSection(bucket: .done, rows: [row()], overflow: 0)]))
        if case .separator = items[0] { Issue.record("leading separator") }
        if case .separator = items[1] { Issue.record("separator after the heading") }
    }

    @Test("renders a workspace row with its project, and without its host")
    func rowLabel() {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [row(hostLabel: "laptop")], overflow: 0)]))
        let labels = items.compactMap { item -> String? in
            if case .workspace(_, let label) = item { return label }
            return nil
        }
        // The host is not in the label: it is its own run, so the panel can
        // draw it smaller and quieter than the workspace it belongs to.
        #expect(labels == ["fix-login  ·  paseo"])
    }

    @Test("hands the host over as its own part, with its separator attached")
    func rowHostSuffix() {
        let withHost = row(hostLabel: "laptop")
        #expect(MenuModel.rowHostSuffix(withHost) == "  ·  laptop")
        #expect(MenuModel.rowLabel(withHost) == "fix-login  ·  paseo")
        // One host configured, so no row names it and there is no punctuation
        // left dangling at the end of the label either.
        #expect(MenuModel.rowHostSuffix(row()) == nil)
        #expect(MenuModel.rowLabel(row()) == "fix-login  ·  paseo")
    }

    @Test("carries the row itself so a click has its ids")
    func rowCarriesTarget() throws {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [row()], overflow: 0)]))
        let target = try #require(items.compactMap { item -> TrayWorkspaceRow? in
            if case .workspace(let row, _) = item { return row }
            return nil
        }.first)
        #expect(target.workspaceId == "w1")
        #expect(target.agentId == "a1")
    }

    @Test("renders the overflow row rather than dropping rows silently")
    func overflow() {
        let items = build(model(sections: [TrayMenuSection(bucket: .needsInput, rows: [], overflow: 3)]))
        let overflow = items.compactMap { item -> String? in
            if case .overflow(_, let label) = item { return label }
            return nil
        }
        #expect(overflow == ["…and 3 more"])
    }

    @Test("offers a retry on an unauthorized host, whose session stopped reconnecting")
    func retryRow() throws {
        let items = build(model(hostStatuses: [
            TrayHostStatus(hostId: "h1", label: "laptop", status: .connected),
            TrayHostStatus(hostId: "h2", label: "studio", status: .unauthorized),
        ]), hostsExpanded: true)
        let hosts = items.compactMap { item -> (String, String, Bool)? in
            if case .hostStatus(let hostId, let label, let retryable) = item { return (hostId, label, retryable) }
            return nil
        }
        #expect(hosts.count == 2)
        #expect(hosts[0] == ("h1", "laptop · connected", false))
        #expect(hosts[1] == ("h2", "studio · authentication failed — retry", true))
    }

    @Test("sums the hosts up in one row, in the same words the rows use")
    func hostSummaryText() {
        func text(_ statuses: [HostStatus]) -> String? {
            summary(build(model(hostStatuses: statuses.enumerated().map {
                TrayHostStatus(hostId: "h\($0.offset)", label: "host\($0.offset)", status: $0.element)
            })))
        }
        #expect(text([.connected, .connected, .connected]) == "3 hosts connected")
        #expect(text([.connected]) == "1 host connected")
        #expect(text([.connected, .connected, .disconnected]) == "2 hosts connected, 1 disconnected")
        // Connected leads even when it is not the first host in the list, and
        // the words are `statusText`'s so the summary and the row it hides
        // never name one state two ways.
        #expect(text([.unauthorized, .connected]) == "1 host connected, 1 authentication failed")
        #expect(text([.connecting, .invalid]) == "1 host connecting, 1 invalid configuration")
        // No connected host at all: the noun goes on whatever is first instead
        // of claiming "0 hosts connected".
        #expect(text([.disconnected, .disconnected]) == "2 hosts disconnected")
    }

    @Test("hides the host rows until the summary is expanded, and never hides the summary")
    func hostsCollapse() {
        let hosts = [
            TrayHostStatus(hostId: "h1", label: "laptop", status: .connected),
            TrayHostStatus(hostId: "h2", label: "studio", status: .disconnected),
        ]
        let collapsed = build(model(hostStatuses: hosts))
        #expect(summary(collapsed) == "1 host connected, 1 disconnected")
        #expect(hostRows(collapsed).isEmpty)

        let expanded = build(model(hostStatuses: hosts), hostsExpanded: true)
        #expect(summary(expanded) == "1 host connected, 1 disconnected")
        #expect(hostRows(expanded) == ["laptop · connected", "studio · disconnected"])
    }

    @Test("carries its own expanded state, so the row can draw which way it points")
    func summaryCarriesState() {
        func expanded(_ items: [MenuItem]) -> Bool? {
            items.compactMap { if case .hostsSummary(_, let expanded) = $0 { expanded } else { nil } }.first
        }
        let hosts = [TrayHostStatus(hostId: "h1", label: "laptop", status: .connected)]
        #expect(expanded(build(model(hostStatuses: hosts))) == false)
        #expect(expanded(build(model(hostStatuses: hosts), hostsExpanded: true)) == true)
    }

    @Test("shows no host block at all when there are no hosts, summary included")
    func noHostsNoSummary() {
        let items = build(model())
        #expect(summary(items) == nil)
        #expect(hostRows(items).isEmpty)
    }

    @Test("surfaces a configuration error as a row carrying the message")
    func configError() throws {
        let items = build(model(configError: "registry error\n\nnot valid JSON"))
        let detail = try #require(items.compactMap { item -> String? in
            if case .configError(let detail) = item { return detail }
            return nil
        }.first)
        #expect(detail.contains("not valid JSON"))
        // First in the menu: the fix for it is what the user came for.
        #expect(items.first?.id == "configError")
    }

    @Test("names the invalid-entry status so a bad host is visible, not missing")
    func invalidStatus() {
        let items = build(model(hostStatuses: [TrayHostStatus(hostId: "h1", label: "my server", status: .invalid)]), hostsExpanded: true)
        let labels = items.compactMap { item -> String? in
            if case .hostStatus(_, let label, _) = item { return label }
            return nil
        }
        #expect(labels == ["my server · invalid configuration"])
    }

    @Test("names a host whose workspace list or agent page was capped")
    func truncationNotes() {
        let items = build(model(truncatedHosts: ["laptop"], agentIndexTruncatedHosts: ["studio"]))
        #expect(notes(items).contains("Not all workspaces shown · laptop"))
        #expect(notes(items).contains("Not all agents loaded · studio"))
    }

    @Test("always offers the footer actions, because a menu bar item cannot rely on click-through")
    func footer() {
        let items = build(model(), loginItemEnabled: true)
        #expect(items.contains(.openApp))
        #expect(items.contains(.loginItem(enabled: true)))
        #expect(items.contains(.quit))
        // Quit is last, and the login item reflects the state it was given.
        #expect(items.last == .quit)
        #expect(!build(model(), loginItemEnabled: false).contains(.loginItem(enabled: true)))
    }

    @Test("names a bucket this build does not know, one row per state")
    func unknownStateRows() {
        let items = build(model(
            sections: [TrayMenuSection(bucket: .done, rows: [row()], overflow: 0)],
            unknownStates: ["quarantined": 1, "blocked": 3]
        ))
        // Sorted only for stability, and each row names its own state and count
        // so the user can tell that their Paseo is ahead of this tray.
        #expect(notes(items) == [
            "3 workspaces in a state this version cannot show · blocked",
            "1 workspace in a state this version cannot show · quarantined",
        ])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("caps the unknown-state rows and says how many states it left out")
    func unknownStateRowsCapped() {
        // Sixteen distinct states this build cannot place. The menu shows the
        // same fifteen a section would and names the remainder, rather than
        // growing a row per state without limit.
        var states: [String: Int] = [:]
        for index in 0..<16 { states[String(format: "state%02d", index)] = 1 }
        let rows = notes(build(model(unknownStates: states)))
        #expect(rows.count == 16)
        #expect(rows.first == "1 workspace in a state this version cannot show · state00")
        #expect(rows.last == "…and 1 more state this version cannot show")
    }

    @Test("does not claim there are no workspaces when the only ones are unknown")
    func unknownStatesAreNotNoWorkspaces() {
        // The rows exist; this build just cannot place them. Saying "No
        // workspaces" here would be the lie the count fix exists to prevent.
        let items = build(model(unknownStates: ["blocked": 2]))
        #expect(!notes(items).contains("No workspaces"))
        #expect(notes(items) == ["2 workspaces in a state this version cannot show · blocked"])
    }

    @Test("keeps two identical truncation notices apart")
    func duplicateNoteIds() {
        // Two hosts the user named the same thing, both truncated. The rows
        // read identically, so an id built from the text alone would make
        // SwiftUI draw one and drop the other's notice — a silent cap.
        let items = build(model(truncatedHosts: ["laptop", "laptop"]))
        #expect(notes(items).filter { $0 == "Not all workspaces shown · laptop" }.count == 2)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("gives every item a distinct identity, so SwiftUI does not collapse two rows")
    func distinctIds() {
        let items = build(model(
            sections: [
                // Both sections overflow by the same number on purpose: the
                // two rows then carry the same label, and only the bucket
                // tells them apart. An id built from the count alone collapses
                // them, and the Failed section loses its overflow row while
                // still hiding rows — a silent cap by another route.
                TrayMenuSection(bucket: .needsInput, rows: [row(), row(workspaceId: "w2")], overflow: 2),
                TrayMenuSection(bucket: .failed, rows: [row(workspaceId: "w3")], overflow: 2),
                TrayMenuSection(bucket: .done, rows: [row(workspaceId: "w4")], overflow: 0),
            ],
            hostStatuses: [TrayHostStatus(hostId: "h1", label: "laptop", status: .connected)],
            truncatedHosts: ["laptop"],
            configError: "boom"
        ))
        #expect(Set(items.map(\.id)).count == items.count)
    }
}
