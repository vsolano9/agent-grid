import Foundation
import Observation

struct AgentGridTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let number: Int

    var title: String {
        "Grid \(number)"
    }
}

@MainActor
@Observable
final class GridTabsModel {
    static let maximumCount = 6

    private(set) var grids: [AgentGridTab]
    private(set) var selectedID: AgentGridTab.ID
    private var nextNumber: Int

    init() {
        let first = AgentGridTab(id: UUID(), number: 1)
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

        let grid = AgentGridTab(id: UUID(), number: nextNumber)
        nextNumber += 1
        grids.append(grid)
        selectedID = grid.id
        return grid
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
}
