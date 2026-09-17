import Foundation

/// One row of the tray menu, as data. The SwiftUI layer renders this and
/// nothing else decides what the menu contains, so the whole menu is testable
/// without a menu bar.
public enum MenuItem: Equatable, Sendable, Identifiable {
    /// A disabled section heading carrying its bucket's icon.
    case sectionHeading(bucket: WorkspaceStateBucket, label: String)
    case workspace(row: TrayWorkspaceRow, label: String)
    /// The capped rows are only reachable in the app, so this opens it. It
    /// carries its section's bucket rather than the count it dropped, because
    /// the count is already in the label and two sections that overflow by the
    /// same number would otherwise share an identity — which is how SwiftUI
    /// renders one overflow row where the menu needs two.
    case overflow(bucket: WorkspaceStateBucket, label: String)
    case separator(index: Int)
    /// A row that does nothing but say something. It is numbered for the same
    /// reason the overflow rows carry their bucket: two hosts whose display
    /// names resolve alike produce byte-identical truncation text, and two
    /// rows sharing an identity means SwiftUI draws one of them.
    case note(index: Int, text: String)
    /// The fix for every configuration error is in the Paseo app.
    case configError(detail: String)
    case hostStatus(hostId: String, label: String, retryable: Bool)
    case openApp
    case loginItem(enabled: Bool)
    case quit

    public var id: String {
        switch self {
        case .sectionHeading(let bucket, _): "heading:\(bucket.rawValue)"
        case .workspace(let row, _): "row:\(row.id)"
        case .overflow(let bucket, _): "overflow:\(bucket.rawValue)"
        case .separator(let index): "sep:\(index)"
        case .note(let index, _): "note:\(index)"
        case .configError: "configError"
        case .hostStatus(let hostId, _, _): "host:\(hostId)"
        case .openApp: "openApp"
        case .loginItem: "loginItem"
        case .quit: "quit"
        }
    }
}

public enum MenuModel {
    static let statusText: [HostStatus: String] = [
        .connecting: "connecting",
        .connected: "connected",
        .disconnected: "disconnected",
        .unauthorized: "authentication failed",
        .invalid: "invalid configuration",
    ]

    public static func rowLabel(_ row: TrayWorkspaceRow) -> String {
        var parts = [row.label, row.projectName]
        if let hostLabel = row.hostLabel { parts.append(hostLabel) }
        return parts.joined(separator: "  ·  ")
    }

    /// The whole menu, in order. Every action lives here: a menu bar item that
    /// needs a click-through for anything is an app with actions some desktops
    /// swallow.
    public static func build(_ model: TrayViewModel, loginItemEnabled: Bool) -> [MenuItem] {
        var items: [MenuItem] = []
        var separators = 0
        var notes = 0
        func note(_ text: String) {
            items.append(.note(index: notes, text: text))
            notes += 1
        }
        func separator() {
            items.append(.separator(index: separators))
            separators += 1
        }

        if let configError = model.configError {
            items.append(.configError(detail: configError))
            separator()
        }

        if model.sections.isEmpty, model.unknownStates.isEmpty {
            note("No workspaces")
        } else {
            // A rule between sections, not before the first: AppKit draws a
            // leading separator as a stray line under the menu's top edge.
            for (index, section) in model.sections.enumerated() {
                if index > 0 { separator() }
                items.append(.sectionHeading(bucket: section.bucket, label: TrayViewModelBuilder.sectionLabels[section.bucket] ?? section.bucket.rawValue))
                items.append(contentsOf: section.rows.map { .workspace(row: $0, label: rowLabel($0)) })
                if section.overflow > 0 {
                    items.append(.overflow(bucket: section.bucket, label: "…and \(section.overflow) more"))
                }
            }
        }

        // A bucket this build does not know, named rather than dropped. Sorted
        // only so the menu is stable between rebuilds: the order carries no
        // ranking, because ranking these is what this build cannot do.
        // Capped like a section, and the remainder named rather than dropped: a
        // daemon whose vocabulary this build wholly fails to recognise could
        // otherwise put one row here for every workspace it sent.
        let unknown = model.unknownStates.sorted { $0.key < $1.key }
        for (status, count) in unknown.prefix(TrayViewModelBuilder.sectionRowCap) {
            note("\(count) workspace\(count == 1 ? "" : "s") in a state this version cannot show · \(status)")
        }
        if unknown.count > TrayViewModelBuilder.sectionRowCap {
            let left = unknown.count - TrayViewModelBuilder.sectionRowCap
            note("…and \(left) more state\(left == 1 ? "" : "s") this version cannot show")
        }

        // The seed page has a ceiling. Reaching it means these rows are a
        // subset, and a subset presented as the whole list is a silent cap.
        for label in model.truncatedHosts {
            note("Not all workspaces shown · \(label)")
        }
        // A capped agent page costs click targets rather than rows: a
        // workspace whose agents fell off the page opens in the browser.
        for label in model.agentIndexTruncatedHosts {
            note("Not all agents loaded · \(label)")
        }

        if !model.hostStatuses.isEmpty {
            separator()
            for host in model.hostStatuses {
                let text = "\(host.label) · \(statusText[host.status] ?? host.status.rawValue)"
                // Auth rejection ends the reconnect loop for good, so without
                // the retry the only way back after fixing the password is
                // relaunching the app.
                let retryable = host.status == .unauthorized
                items.append(.hostStatus(hostId: host.hostId, label: retryable ? "\(text) — retry" : text, retryable: retryable))
            }
        }

        separator()
        items.append(.openApp)
        items.append(.loginItem(enabled: loginItemEnabled))
        separator()
        items.append(.quit)
        return items
    }
}
