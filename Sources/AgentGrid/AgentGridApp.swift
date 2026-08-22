import SwiftUI

@main
struct AgentGridApp: App {
    private let configuration = AgentGridConfiguration.live()

    var body: some Scene {
        Window("AgentGrid", id: "main") {
            TerminalGridView(configuration: configuration)
                .frame(minWidth: 800, minHeight: 520)
                .background(WindowMaximizer())
        }
        .defaultSize(width: 1_280, height: 800)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}
