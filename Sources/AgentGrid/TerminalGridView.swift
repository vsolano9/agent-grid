import SwiftUI

enum TerminalGridLayoutPolicy {
    static func prefersFocus(at position: AgentPanePosition) -> Bool {
        position == .topLeft
    }
}

struct AgentGridConfiguration: Sendable {
    let catalog: [AgentLaunchSpec]
    let environment: [String: String]
    let workspace: URL

    func launchSpecs(
        for selection: AgentGridSelection,
        workingDirectory: URL? = nil
    ) -> [AgentLaunchSpec] {
        let specsByKind = Dictionary(
            uniqueKeysWithValues: catalog.map { ($0.kind, $0) }
        )

        let selectedWorkspace = workingDirectory ?? workspace

        return selection.agents.map { kind in
            guard let spec = specsByKind[kind] else {
                preconditionFailure("Missing launch specification for \(kind.rawValue)")
            }
            return AgentLaunchSpec(
                kind: spec.kind,
                executable: spec.executable,
                arguments: spec.arguments,
                workingDirectory: selectedWorkspace
            )
        }
    }

    static func live(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let environment = TerminalEnvironment.make(
            base: baseEnvironment,
            homeDirectory: homeDirectory
        )
        let resolver = BinaryResolver(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let workspace = WorkspaceLocator(homeDirectory: homeDirectory).workspace()

        return Self(
            catalog: AgentLaunchCatalog.makeSupported(
                workspace: workspace,
                resolver: resolver
            ),
            environment: environment,
            workspace: workspace
        )
    }
}

struct TerminalGridView: View {
    let specs: [AgentLaunchSpec]
    let environment: [String: String]
    let isWindowPrepared: Bool
    var isActive = true

    var body: some View {
        VStack(spacing: 1) {
            terminalRow(
                specs[0],
                leadingPosition: .topLeft,
                specs[1]
            )
            terminalRow(
                specs[2],
                leadingPosition: .bottomLeft,
                specs[3]
            )
        }
        .background(Color(nsColor: .separatorColor))
    }

    private func terminalRow(
        _ leading: AgentLaunchSpec,
        leadingPosition: AgentPanePosition,
        _ trailing: AgentLaunchSpec
    ) -> some View {
        HStack(spacing: 1) {
            TerminalPane(
                spec: leading,
                environment: environment,
                isWindowPrepared: isWindowPrepared,
                isGridActive: isActive,
                prefersFocus: TerminalGridLayoutPolicy.prefersFocus(at: leadingPosition)
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalPane(
                spec: trailing,
                environment: environment,
                isWindowPrepared: isWindowPrepared,
                isGridActive: isActive,
                prefersFocus: false
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TerminalGridDeck: View {
    let grids: [AgentGridTab]
    let selectedID: AgentGridTab.ID
    let configuration: AgentGridConfiguration
    let isWindowPrepared: Bool

    var body: some View {
        ZStack {
            ForEach(grids) { grid in
                if let selection = grid.launchedSelection,
                   let workingDirectory = grid.launchedWorkingDirectory {
                    let isSelected = grid.id == selectedID

                    TerminalGridView(
                        specs: configuration.launchSpecs(
                            for: selection,
                            workingDirectory: workingDirectory
                        ),
                        environment: configuration.environment,
                        isWindowPrepared: isWindowPrepared,
                        isActive: isSelected
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
                }
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}
