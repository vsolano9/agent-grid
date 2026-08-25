import Foundation
import Testing
@testable import AgentGrid

@MainActor
struct GridSelectionStoreTests {
    @Test("UserDefaults store restores valid choices and ignores corrupt records")
    func restoreAndRepair() throws {
        let suiteName = "AgentGridTests.GridSelectionStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([
            "1": ["hermes", "hermes", "hermes", "hermes"],
            "2": ["unknown", "claude", "grok", "cursor"],
        ], forKey: UserDefaultsGridSelectionStore.storageKey)
        let store = UserDefaultsGridSelectionStore(userDefaults: defaults)

        #expect(store.selection(forGrid: 1)?.agents == [
            .hermes, .hermes, .hermes, .hermes,
        ])
        #expect(store.selection(forGrid: 2) == nil)

        store.save(.standard, forGrid: 2)
        #expect(store.selection(forGrid: 1)?.agents == [
            .hermes, .hermes, .hermes, .hermes,
        ])
        #expect(store.selection(forGrid: 2) == .standard)
    }
}
