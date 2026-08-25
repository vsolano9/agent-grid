import Foundation

protocol CLIUsageReading: Sendable {
    func fetch() async -> [AgentKind: CLIUsageState]
}

protocol ProviderQuotaReading: Sendable {
    func fetchRemainingPercent() async throws -> Int
}

actor CLIUsageService: CLIUsageReading {
    static let displayedKinds: [AgentKind] = [.codex, .claude, .grok, .cursor]

    private let readers: [AgentKind: any ProviderQuotaReading]
    private var lastGood: [AgentKind: Int] = [:]

    init(readers: [AgentKind: any ProviderQuotaReading]) {
        self.readers = readers
    }

    func fetch() async -> [AgentKind: CLIUsageState] {
        let results = await withTaskGroup(
            of: ProviderFetchResult.self,
            returning: [AgentKind: Int?].self
        ) { group in
            for kind in Self.displayedKinds {
                guard let reader = readers[kind] else { continue }
                group.addTask {
                    do {
                        return ProviderFetchResult(
                            kind: kind,
                            remainingPercent: try await reader.fetchRemainingPercent()
                        )
                    } catch {
                        return ProviderFetchResult(kind: kind, remainingPercent: nil)
                    }
                }
            }

            var values: [AgentKind: Int?] = [:]
            for await result in group {
                values[result.kind] = result.remainingPercent
            }
            return values
        }

        return Self.displayedKinds.reduce(into: [:]) { states, kind in
            if let result = results[kind], let remainingPercent = result {
                let bounded = min(max(remainingPercent, 0), 100)
                lastGood[kind] = bounded
                states[kind] = .available(remainingPercent: bounded)
            } else if let previous = lastGood[kind] {
                states[kind] = .stale(
                    remainingPercent: previous,
                    reason: Self.failureReason(for: kind)
                )
            } else {
                states[kind] = .unavailable(reason: Self.failureReason(for: kind))
            }
        }
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let terminalEnvironment = TerminalEnvironment.make(
            base: environment,
            homeDirectory: homeDirectory
        )
        let transport = URLSessionProviderUsageHTTPTransport()
        return Self(readers: [
            .codex: CodexUsageReader(
                executable: homeDirectory.appendingPathComponent(".local/bin/codex"),
                environment: terminalEnvironment
            ),
            .claude: ClaudeUsageReader(
                accessTokenLoader: ClaudeAccessTokenStore(
                    environment: environment,
                    homeDirectory: homeDirectory
                ),
                transport: transport
            ),
            .grok: GrokUsageReader(
                accessTokenLoader: GrokAccessTokenStore(
                    environment: environment,
                    homeDirectory: homeDirectory
                ),
                transport: transport
            ),
            .cursor: CursorUsageReader(
                accessTokenLoader: CursorAccessTokenStore(
                    environment: environment,
                    homeDirectory: homeDirectory
                ),
                transport: transport
            ),
        ])
    }

    private static func failureReason(for kind: AgentKind) -> String {
        switch kind {
        case .codex: "Codex quota could not be refreshed."
        case .claude: "Claude quota could not be refreshed."
        case .grok: "Grok quota could not be refreshed."
        case .cursor: "Cursor quota could not be refreshed."
        case .hermes: "Hermes routes account quota through another provider."
        }
    }
}

private struct ProviderFetchResult: Sendable {
    let kind: AgentKind
    let remainingPercent: Int?
}
