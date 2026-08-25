import Foundation

protocol CLIUsageReading: Sendable {
    func fetch() async -> [AgentKind: CLIUsageState]
}

protocol CodexQuotaReading: Sendable {
    func fetch() async throws -> CLIUsageState
}

struct CLIUsageService: CLIUsageReading, Sendable {
    let codexReader: any CodexQuotaReading

    func fetch() async -> [AgentKind: CLIUsageState] {
        let codex: CLIUsageState
        do {
            codex = try await codexReader.fetch()
        } catch {
            codex = .unavailable(reason: "Codex quota could not be refreshed.")
        }

        return [
            .codex: codex,
            .claude: .unavailable(
                reason: "Claude shows plan limits in the interactive /usage screen, but exposes no supported structured quota command."
            ),
            .grok: .unavailable(
                reason: "Grok shows its weekly pool under Settings → Usage, but exposes no supported structured CLI quota command."
            ),
            .cursor: .unavailable(
                reason: "Cursor shows current allowance in the Spending dashboard, not through Cursor Agent CLI."
            ),
            .hermes: .unavailable(
                reason: "Hermes /usage reports session tokens; account quota belongs to whichever provider the session routes through."
            ),
        ]
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let terminalEnvironment = TerminalEnvironment.make(
            base: environment,
            homeDirectory: homeDirectory
        )
        return Self(
            codexReader: CodexUsageReader(
                executable: homeDirectory.appendingPathComponent(".local/bin/codex"),
                environment: terminalEnvironment
            )
        )
    }
}
