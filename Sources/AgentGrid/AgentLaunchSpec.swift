import Foundation

enum AgentKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case codex
    case claude
    case grok
    case cursor
    case hermes

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .cursor: "Cursor Agent"
        case .hermes: "Hermes Agent"
        }
    }

    var executableName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .grok: "grok"
        case .cursor: "cursor-agent"
        case .hermes: "hermes"
        }
    }

    var yoloArguments: [String] {
        switch self {
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .claude: ["--dangerously-skip-permissions"]
        case .grok: ["--always-approve"]
        case .cursor: ["--yolo"]
        case .hermes: ["--yolo"]
        }
    }
}

enum AgentPanePosition: Int, CaseIterable, Equatable, Hashable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

struct AgentGridSelection: Equatable, Sendable {
    static let paneCount = 4
    static let standard = AgentGridSelection(
        uncheckedAgents: [.codex, .claude, .grok, .cursor]
    )

    let agents: [AgentKind]

    init?(agents: [AgentKind]) {
        guard agents.count == Self.paneCount else { return nil }
        self.agents = agents
    }

    func agent(at position: AgentPanePosition) -> AgentKind {
        agents[position.rawValue]
    }

    func replacingAgent(
        at position: AgentPanePosition,
        with agent: AgentKind
    ) -> Self {
        var updatedAgents = agents
        updatedAgents[position.rawValue] = agent
        return Self(uncheckedAgents: updatedAgents)
    }

    private init(uncheckedAgents: [AgentKind]) {
        agents = uncheckedAgents
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
        selection: AgentGridSelection = .standard,
        workspace: URL,
        resolver: some ExecutableResolving
    ) -> [AgentLaunchSpec] {
        make(kinds: selection.agents, workspace: workspace, resolver: resolver)
    }

    static func makeSupported(
        workspace: URL,
        resolver: some ExecutableResolving
    ) -> [AgentLaunchSpec] {
        make(kinds: AgentKind.allCases, workspace: workspace, resolver: resolver)
    }

    private static func make(
        kinds: [AgentKind],
        workspace: URL,
        resolver: some ExecutableResolving
    ) -> [AgentLaunchSpec] {
        kinds.map { kind in
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
