import Foundation

enum AgentKind: String, CaseIterable, Equatable, Sendable {
    case codex
    case claude
    case grok
    case cursor

    var executableName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .grok: "grok"
        case .cursor: "cursor-agent"
        }
    }

    var yoloArguments: [String] {
        switch self {
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .claude: ["--dangerously-skip-permissions"]
        case .grok: ["--always-approve"]
        case .cursor: ["--yolo"]
        }
    }
}

struct AgentLaunchSpec: Equatable, Sendable {
    let kind: AgentKind
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
}

protocol ExecutableResolving: Sendable {
    func resolve(_ executableName: String) -> URL?
}

enum AgentLaunchCatalog {
    static func make(
        workspace: URL,
        resolver: some ExecutableResolving
    ) -> [AgentLaunchSpec] {
        AgentKind.allCases.map { kind in
            let resolvedExecutable = resolver.resolve(kind.executableName)
            let executable = resolvedExecutable
                ?? URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
            let arguments = resolvedExecutable == nil
                ? [kind.executableName] + kind.yoloArguments
                : kind.yoloArguments

            return AgentLaunchSpec(
                kind: kind,
                executable: executable,
                arguments: arguments,
                workingDirectory: workspace
            )
        }
    }
}
