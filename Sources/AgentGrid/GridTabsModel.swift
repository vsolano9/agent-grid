import Foundation
import Observation

struct AgentGridTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let number: Int
    var draftSelection: AgentGridSelection
    var launchedSelection: AgentGridSelection?
    var draftWorkingDirectory: URL
    var launchedWorkingDirectory: URL?

    var title: String {
        "Grid \(number)"
    }

    var isLaunched: Bool {
        launchedSelection != nil
    }
}

@MainActor
@Observable
final class GridTabsModel {
    static let maximumCount = 6

    private(set) var grids: [AgentGridTab]
    private(set) var selectedID: AgentGridTab.ID
    private var nextNumber: Int
    private let defaultWorkspace: URL

    init(defaultWorkspace: URL = WorkspaceLocator.workRoot) {
        self.defaultWorkspace = defaultWorkspace
        let first = Self.makeDraft(number: 1, workspace: defaultWorkspace)
        grids = [first]
        selectedID = first.id
        nextNumber = 2
    }

    var canAdd: Bool {
        grids.count < Self.maximumCount
    }

    var canClose: Bool {
        grids.count > 1
    }

    @discardableResult
    func addGrid() -> AgentGridTab? {
        guard canAdd else { return nil }

        let grid = Self.makeDraft(number: nextNumber, workspace: defaultWorkspace)
        nextNumber += 1
        grids.append(grid)
        selectedID = grid.id
        return grid
    }

    func grid(id: AgentGridTab.ID) -> AgentGridTab? {
        grids.first { $0.id == id }
    }

    func setAgent(
        _ agent: AgentKind,
        at position: AgentPanePosition,
        in id: AgentGridTab.ID
    ) {
        guard let index = grids.firstIndex(where: { $0.id == id }),
              !grids[index].isLaunched else {
            return
        }

        grids[index].draftSelection = grids[index].draftSelection.replacingAgent(
            at: position,
            with: agent
        )
    }

    func setWorkingDirectory(_ directory: URL, in id: AgentGridTab.ID) {
        guard let index = grids.firstIndex(where: { $0.id == id }),
              !grids[index].isLaunched else {
            return
        }

        grids[index].draftWorkingDirectory = directory.standardizedFileURL
    }

    @discardableResult
    func launch(_ id: AgentGridTab.ID) -> Bool {
        guard let index = grids.firstIndex(where: { $0.id == id }),
              !grids[index].isLaunched else {
            return false
        }

        grids[index].launchedSelection = grids[index].draftSelection
        grids[index].launchedWorkingDirectory = grids[index].draftWorkingDirectory
        return true
    }

    func select(_ id: AgentGridTab.ID) {
        guard grids.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func close(_ id: AgentGridTab.ID) {
        guard canClose,
              let index = grids.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasSelected = selectedID == id
        grids.remove(at: index)

        if wasSelected {
            selectedID = grids[min(index, grids.count - 1)].id
        }
    }

    private static func makeDraft(number: Int, workspace: URL) -> AgentGridTab {
        AgentGridTab(
            id: UUID(),
            number: number,
            draftSelection: .standard,
            launchedSelection: nil,
            draftWorkingDirectory: workspace.standardizedFileURL,
            launchedWorkingDirectory: nil
        )
    }
}
