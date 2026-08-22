import Foundation
import Testing
@testable import AgentGrid

@MainActor
@Suite("Multi-grid tab policy")
struct GridTabsModelTests {
    @Test("starts with one selected grid")
    func initialState() throws {
        let model = GridTabsModel()
        let first = try #require(model.grids.first)

        #expect(model.grids.map(\.title) == ["Grid 1"])
        #expect(model.selectedID == first.id)
        #expect(model.canAdd)
        #expect(!model.canClose)
    }

    @Test("adding selects a monotonically named grid")
    func addGrid() throws {
        let model = GridTabsModel()

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
        let model = GridTabsModel()
        let first = try #require(model.grids.first)
        let second = try #require(model.addGrid())

        model.select(first.id)
        model.select(UUID())

        #expect(model.selectedID == first.id)
        #expect(model.selectedID != second.id)
    }

    @Test("closing the selected middle grid selects the grid moving into its slot")
    func closeSelectedMiddle() throws {
        let model = GridTabsModel()
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.select(second.id)
        model.close(second.id)

        #expect(model.selectedID == third.id)
        #expect(model.grids.map(\.title) == ["Grid 1", "Grid 3"])
    }

    @Test("closing the selected final grid selects its predecessor")
    func closeSelectedFinal() throws {
        let model = GridTabsModel()
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.close(third.id)

        #expect(model.selectedID == second.id)
    }

    @Test("closing an inactive grid preserves selection and surviving identities")
    func closeInactive() throws {
        let model = GridTabsModel()
        let first = try #require(model.grids.first)
        let second = try #require(model.addGrid())
        let third = try #require(model.addGrid())

        model.close(first.id)

        #expect(model.selectedID == third.id)
        #expect(model.grids.map(\.id) == [second.id, third.id])
    }

    @Test("the final grid cannot close and the collection is capped at six")
    func bounds() throws {
        let model = GridTabsModel()
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
