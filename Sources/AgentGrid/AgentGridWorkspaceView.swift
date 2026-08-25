import SwiftUI

struct AgentGridWorkspaceView: View {
    let configuration: AgentGridConfiguration
    let isWindowPrepared: Bool
    let maintenanceWarnings: [AgentKind]

    @State private var tabs: GridTabsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let motion = Animation.easeOut(duration: 0.14)

    init(
        configuration: AgentGridConfiguration,
        isWindowPrepared: Bool,
        maintenanceWarnings: [AgentKind] = []
    ) {
        self.configuration = configuration
        self.isWindowPrepared = isWindowPrepared
        self.maintenanceWarnings = maintenanceWarnings
        _tabs = State(
            initialValue: GridTabsModel(defaultWorkspace: configuration.workspace)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            GridTabStrip(model: tabs)
            ZStack {
                TerminalGridDeck(
                    grids: tabs.grids,
                    selectedID: tabs.selectedID,
                    configuration: configuration,
                    isWindowPrepared: isWindowPrepared
                )

                if let grid = tabs.grid(id: tabs.selectedID), !grid.isLaunched {
                    GridSetupView(
                        grid: grid,
                        maintenanceWarnings: maintenanceWarnings,
                        setAgent: { agent, position in
                            tabs.setAgent(agent, at: position, in: grid.id)
                        },
                        setWorkingDirectory: { directory in
                            tabs.setWorkingDirectory(directory, in: grid.id)
                        },
                        launch: {
                            withAnimation(reduceMotion ? nil : Self.motion) {
                                _ = tabs.launch(grid.id)
                            }
                        }
                    )
                    .transition(
                        reduceMotion
                            ? AnyTransition.identity
                            : AnyTransition.opacity.combined(
                                with: AnyTransition.scale(scale: 0.985)
                            )
                    )
                    .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0, green: 0, blue: 0))
    }
}
