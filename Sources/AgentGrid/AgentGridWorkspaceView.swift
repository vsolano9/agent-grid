import SwiftUI

struct AgentGridWorkspaceView: View {
    let configuration: AgentGridConfiguration
    let isWindowPrepared: Bool

    @State private var tabs = GridTabsModel()

    var body: some View {
        VStack(spacing: 0) {
            GridTabStrip(model: tabs)
            TerminalGridDeck(
                grids: tabs.grids,
                selectedID: tabs.selectedID,
                configuration: configuration,
                isWindowPrepared: isWindowPrepared
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }
}
