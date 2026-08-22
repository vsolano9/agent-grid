import SwiftUI

struct AgentGridConfiguration: Sendable {
    let specs: [AgentLaunchSpec]
    let environment: [String: String]

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
            specs: AgentLaunchCatalog.make(workspace: workspace, resolver: resolver),
            environment: environment
        )
    }
}

struct TerminalGridView: View {
    let configuration: AgentGridConfiguration
    let isWindowPrepared: Bool
    var isActive = true

    var body: some View {
        VStack(spacing: 1) {
            terminalRow(configuration.specs[0], configuration.specs[1])
            terminalRow(configuration.specs[2], configuration.specs[3])
        }
        .background(Color(nsColor: .separatorColor))
    }

    private func terminalRow(
        _ leading: AgentLaunchSpec,
        _ trailing: AgentLaunchSpec
    ) -> some View {
        HStack(spacing: 1) {
            TerminalPane(
                spec: leading,
                environment: configuration.environment,
                isWindowPrepared: isWindowPrepared,
                isGridActive: isActive,
                prefersFocus: leading.kind == .codex
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalPane(
                spec: trailing,
                environment: configuration.environment,
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
                let isSelected = grid.id == selectedID

                TerminalGridView(
                    configuration: configuration,
                    isWindowPrepared: isWindowPrepared,
                    isActive: isSelected
                )
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .zIndex(isSelected ? 1 : 0)
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}
