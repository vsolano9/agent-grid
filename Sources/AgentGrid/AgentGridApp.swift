import SwiftUI

@main
struct AgentGridApp: App {
    @State private var windowState = AgentGridWindowState()
    @State private var maintenance = CLIMaintenanceModel()

    var body: some Scene {
        Window("AgentGrid", id: "main") {
            Group {
                if let configuration = maintenance.configuration {
                    AgentGridWorkspaceView(
                        configuration: configuration,
                        isWindowPrepared: windowState.isPrepared,
                        maintenanceWarnings: maintenance.warningKinds
                    )
                } else {
                    CLIMaintenanceView(
                        phase: maintenance.phase,
                        retry: {
                            Task { await maintenance.retry() }
                        }
                    )
                }
            }
                .task { await maintenance.start() }
                .frame(minWidth: 800, minHeight: 520)
                .background(WindowMaximizer(state: windowState))
        }
        .defaultSize(width: 1_280, height: 800)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}
