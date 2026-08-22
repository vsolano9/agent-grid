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
            TerminalPane(spec: leading, environment: configuration.environment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalPane(spec: trailing, environment: configuration.environment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}
