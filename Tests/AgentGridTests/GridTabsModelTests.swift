import Foundation
import Testing
@testable import AgentGrid

@MainActor
@Suite("Multi-grid tab policy")
struct GridTabsModelTests {
    @Test("starts with one selected grid")
    func initialState() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)

        #expect(model.grids.map(\.title) == ["Grid 1"])
        #expect(model.selectedID == first.id)
        #expect(first.draftSelection == .standard)
        #expect(first.launchedSelection == nil)
        #expect(model.canAdd)
        #expect(!model.canClose)
    }

    @Test("draft pane choices allow duplicates and freeze when launched")
    func configureAndLaunch() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)

        for position in AgentPanePosition.allCases {
            model.setAgent(.codex, at: position, in: first.id)
        }
        let draft = try #require(model.grid(id: first.id))
        #expect(draft.draftSelection.agents == [.codex, .codex, .codex, .codex])

        #expect(model.launch(first.id))
        let launched = try #require(model.grid(id: first.id))
        #expect(launched.launchedSelection == launched.draftSelection)

        model.setAgent(.claude, at: .topLeft, in: first.id)
        #expect(model.grid(id: first.id)?.draftSelection == launched.draftSelection)
        #expect(!model.launch(first.id))
    }

    @Test("every added grid gets an independent setup draft")
    func independentDrafts() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)
        model.setAgent(.codex, at: .topRight, in: first.id)

        let second = try #require(model.addGrid())

        #expect(second.draftSelection == .standard)
        #expect(second.launchedSelection == nil)
        #expect(model.grid(id: first.id)?.draftSelection.agents == [
            .codex, .codex, .grok, .cursor,
        ])
        #expect(model.grid(id: second.id)?.draftSelection == .standard)
    }

    @Test("each grid restores and saves its own CLI choices across model relaunches")
    func persistentGridChoices() throws {
        let allHermes = try #require(AgentGridSelection(
            agents: Array(repeating: .hermes, count: AgentGridSelection.paneCount)
        ))
        let allClaude = try #require(AgentGridSelection(
            agents: Array(repeating: .claude, count: AgentGridSelection.paneCount)
        ))
        let store = InMemoryGridSelectionStore(selections: [
            1: allHermes,
            2: allClaude,
        ])

        let firstRun = GridTabsModel(selectionStore: store)
        let first = try #require(firstRun.grids.first)
        let second = try #require(firstRun.addGrid())

        #expect(first.draftSelection == allHermes)
        #expect(second.draftSelection == allClaude)

        firstRun.setAgent(.grok, at: .topLeft, in: second.id)
        #expect(store.selection(forGrid: 2)?.agents == [
            .grok, .claude, .claude, .claude,
        ])

        let relaunched = GridTabsModel(selectionStore: store)
        let restoredFirst = try #require(relaunched.grids.first)
        let restoredSecond = try #require(relaunched.addGrid())
        #expect(restoredFirst.draftSelection == allHermes)
        #expect(restoredSecond.draftSelection.agents == [
            .grok, .claude, .claude, .claude,
        ])
    }

    @Test("each grid starts in the default folder and freezes its own directory at launch")
    func perGridWorkingDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        let custom = URL(fileURLWithPath: "/Users/test/Projects/apps")
        let ignored = URL(fileURLWithPath: "/tmp")
        let store = InMemoryGridSelectionStore()
        let model = GridTabsModel(
            workspaceLocator: WorkspaceLocator(homeDirectory: home, isDirectory: { _ in true }),
            selectionStore: store
        )
        let first = try #require(model.grids.first)

        #expect(first.draftWorkingDirectory == home)
        #expect(first.launchedWorkingDirectory == nil)

        model.setWorkingDirectory(custom, in: first.id)
        #expect(model.grid(id: first.id)?.draftWorkingDirectory == custom)
        #expect(model.launch(first.id))
        #expect(model.grid(id: first.id)?.launchedWorkingDirectory == custom)

        model.setWorkingDirectory(ignored, in: first.id)
        #expect(model.grid(id: first.id)?.draftWorkingDirectory == custom)

        let second = try #require(model.addGrid())
        #expect(second.draftWorkingDirectory == custom)
        #expect(second.launchedWorkingDirectory == nil)
    }

    @Test("adding selects a monotonically named grid")
    func addGrid() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())

        let second = try #require(model.addGrid())
        model.close(second.id)
        let third = try #require(model.addGrid())

        #expect(second.title == "Grid 2")
        #expect(third.title == "Grid 3")
        #expect(model.selectedID == third.id)
        #expect(model.grids.map(\.title) == ["Grid 1", "Grid 3"])
    }

    @Test("select ignores IDs outside the open collection")
    func selection() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)
        let second = try #require(model.addGrid())

        model.select(first.id)
        model.select(UUID())

        #expect(model.selectedID == first.id)
        #expect(model.selectedID != second.id)
    }

    @Test("closing the selected middle grid selects the grid moving into its slot")
    func closeSelectedMiddle() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.select(second.id)
        model.close(second.id)

        #expect(model.selectedID == third.id)
        #expect(model.grids.map(\.title) == ["Grid 1", "Grid 3"])
    }

    @Test("closing the selected final grid selects its predecessor")
    func closeSelectedFinal() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.close(third.id)

        #expect(model.selectedID == second.id)
    }

    @Test("closing an inactive grid preserves selection and surviving identities")
    func closeInactive() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.close(first.id)

        #expect(model.selectedID == third.id)
        #expect(model.grids.map(\.id) == [second.id, third.id])
    }

    @Test("the final grid cannot close and the collection is capped at six")
    func bounds() throws {
        let model = GridTabsModel(selectionStore: InMemoryGridSelectionStore())
        let first = try #require(model.grids.first)

        model.close(first.id)
        for _ in 0..<10 {
            model.addGrid()
        }

        #expect(model.grids.count == GridTabsModel.maximumCount)
        #expect(!model.canAdd)
        #expect(model.canClose)
        #expect(model.grids.first?.id == first.id)
    }
}

private final class InMemoryGridSelectionStore: GridSelectionPersisting {
    private var selections: [Int: AgentGridSelection]
    private var workingDirectory: URL?

    init(selections: [Int: AgentGridSelection] = [:]) {
        self.selections = selections
    }

    func selection(forGrid number: Int) -> AgentGridSelection? {
        selections[number]
    }

    func save(_ selection: AgentGridSelection, forGrid number: Int) {
        selections[number] = selection
    }

    func defaultWorkingDirectory() -> URL? {
        workingDirectory
    }

    func saveDefaultWorkingDirectory(_ directory: URL) {
        workingDirectory = directory
    }
}
