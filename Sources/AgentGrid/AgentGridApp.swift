import SwiftUI

@main
struct AgentGridApp: App {
    private let configuration = AgentGridConfiguration.live()
    @State private var windowState = AgentGridWindowState()

    var body: some Scene {
        Window("AgentGrid", id: "main") {
            AgentGridWorkspaceView(
                configuration: configuration,
                isWindowPrepared: windowState.isPrepared
            )
                .frame(minWidth: 800, minHeight: 520)
                .background(WindowMaximizer(state: windowState))
        }
        .defaultSize(width: 1_280, height: 800)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}
