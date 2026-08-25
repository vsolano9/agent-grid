import Foundation

struct CLIExecutableLocator: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.isExecutable = isExecutable
    }

    func locate(_ kind: AgentKind) -> URL? {
        let aliasDirectory = canonicalAliasDirectory
        let providerCandidates = providerCandidates(for: kind)
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let searchCandidates = unique(
            pathDirectories + TerminalEnvironment.fallbackDirectories(homeDirectory: homeDirectory)
        )
        .filter { $0.standardizedFileURL != aliasDirectory }
        .map { $0.appendingPathComponent(kind.executableName, isDirectory: false) }

        return (providerCandidates + searchCandidates).first {
            isExecutable($0.path)
        }
    }

    private var canonicalAliasDirectory: URL {
        homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .standardizedFileURL
    }

    private func providerCandidates(for kind: AgentKind) -> [URL] {
        switch kind {
        case .grok:
            return [homeDirectory.appendingPathComponent(".grok/bin/grok")]
        case .cursor:
            let versionsDirectory = homeDirectory.appendingPathComponent(
                ".local/share/cursor-agent/versions",
                isDirectory: true
            )
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: versionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("cursor-agent", isDirectory: false) }
        case .hermes:
            return [
                homeDirectory.appendingPathComponent(
                    ".hermes/hermes-agent/venv/bin/hermes",
                    isDirectory: false
                ),
                homeDirectory.appendingPathComponent(
                    ".hermes/hermes-agent/hermes",
                    isDirectory: false
                ),
            ]
        case .codex, .claude:
            return []
        }
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
