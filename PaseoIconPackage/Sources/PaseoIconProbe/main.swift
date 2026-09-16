import AppKit
import Foundation
import PaseoIconCore

// A terminal probe for one host: prints every status transition, the
// server_info, the seeded counts, and each streamed update until Ctrl-C.
// This is how relay connectivity is checked against a real host without a
// menu bar in the loop.
//
//   swift run PaseoIconProbe --offer 'paseo://…#offer=…'
//   swift run PaseoIconProbe --endpoint 127.0.0.1:6767 [--password secret] [--tls]

@MainActor
final class PrintingSink: HostSink {
    func setHost(_ hostId: String, label: String?, endpointHint: String) {
        print("host \(hostId): label=\(label ?? "-") endpoint=\(endpointHint)")
    }
    func removeHost(_ hostId: String) { print("host \(hostId): removed") }
    func setStatus(_ hostId: String, _ status: HostStatus) { print("status: \(status.rawValue)") }
    func setServerId(_ hostId: String, _ serverId: String) { print("serverId: \(serverId)") }
    func setHostname(_ hostId: String, _ hostname: String?) { print("hostname: \(hostname ?? "-")") }
    func seedAgents(_ hostId: String, _ agents: [AgentSnapshot], truncated: Bool) {
        print("seeded \(agents.count) agents\(truncated ? " (truncated)" : "")")
    }
    func seedWorkspaces(_ hostId: String, _ workspaces: [WorkspaceDescriptor], truncated: Bool) {
        print("seeded \(workspaces.count) workspaces\(truncated ? " (truncated)" : "")")
        for workspace in workspaces {
            print("  \(workspace.status)\t\(workspace.projectDisplayName) / \(workspace.name)")
        }
    }
    func applyAgentUpdate(_ hostId: String, _ update: AgentUpdate) {
        switch update {
        case .upsert(let agent): print("agent upsert: \(agent.id) status=\(agent.status)")
        case .remove(let agentId): print("agent remove: \(agentId)")
        }
    }
    func applyWorkspaceUpdate(_ hostId: String, _ update: WorkspaceUpdate) {
        switch update {
        case .upsert(let workspace): print("workspace upsert: \(workspace.name) status=\(workspace.status)")
        case .remove(let id): print("workspace remove: \(id)")
        }
    }
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: PaseoIconProbe --offer <pairing url>
           PaseoIconProbe --endpoint <host:port> [--password <password>] [--tls]

    """.utf8))
    exit(2)
}

func parseEntry(_ arguments: [String]) -> HostEntry {
    var offer: String?
    var endpoint: String?
    var password: String?
    var tls = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() -> String {
            index += 1
            guard index < arguments.count else { usage() }
            return arguments[index]
        }
        switch argument {
        case "--offer": offer = value()
        case "--endpoint": endpoint = value()
        case "--password": password = value()
        case "--tls": tls = true
        default: usage()
        }
        index += 1
    }
    if let offer {
        do {
            return .relay(id: "probe", label: nil, offer: try ConnectionOffer.parse(fromURL: offer))
        } catch {
            FileHandle.standardError.write(Data("invalid offer: \(error)\n".utf8))
            exit(2)
        }
    }
    if let endpoint {
        return .directTcp(id: "probe", label: nil, endpoint: endpoint, useTls: tls, password: password)
    }
    usage()
}

// Line-buffer stdout so transitions show up as they happen when piped to a file or another process.
setvbuf(stdout, nil, _IOLBF, 0)
let entry = parseEntry(Array(CommandLine.arguments.dropFirst()))
let sink = PrintingSink()
let connection: HostConnection
do {
    connection = try HostConnection(entry: entry, sink: sink, clock: ContinuousClock())
} catch {
    FileHandle.standardError.write(Data("cannot dial: \(error)\n".utf8))
    exit(2)
}
signal(SIGINT) { _ in exit(0) }
withExtendedLifetime(connection) {
    RunLoop.main.run()
}
