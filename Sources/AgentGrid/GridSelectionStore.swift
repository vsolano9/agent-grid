import Foundation

@MainActor
protocol GridSelectionPersisting: AnyObject {
    func selection(forGrid number: Int) -> AgentGridSelection?
    func save(_ selection: AgentGridSelection, forGrid number: Int)
    func defaultWorkingDirectory() -> URL?
    func saveDefaultWorkingDirectory(_ directory: URL)
}

@MainActor
final class UserDefaultsGridSelectionStore: GridSelectionPersisting {
    static let storageKey = "agentGrid.agentSelectionsByGrid.v1"
    static let workingDirectoryKey = "agentGrid.defaultWorkingDirectory.v1"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func selection(forGrid number: Int) -> AgentGridSelection? {
        guard number > 0,
              let records = userDefaults.dictionary(forKey: Self.storageKey),
              let rawAgents = records[String(number)] as? [String] else {
            return nil
        }

        let agents = rawAgents.compactMap(AgentKind.init(rawValue:))
        guard agents.count == rawAgents.count else { return nil }
        return AgentGridSelection(agents: agents)
    }

    func save(_ selection: AgentGridSelection, forGrid number: Int) {
        guard number > 0 else { return }
        var records = userDefaults.dictionary(forKey: Self.storageKey) ?? [:]
        records[String(number)] = selection.agents.map(\.rawValue)
        userDefaults.set(records, forKey: Self.storageKey)
    }

    func defaultWorkingDirectory() -> URL? {
        guard let path = userDefaults.string(forKey: Self.workingDirectoryKey),
              path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func saveDefaultWorkingDirectory(_ directory: URL) {
        guard directory.isFileURL else { return }
        userDefaults.set(directory.standardizedFileURL.path, forKey: Self.workingDirectoryKey)
    }
}
