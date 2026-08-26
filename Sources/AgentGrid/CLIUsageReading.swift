import Foundation

protocol CLIUsageReading: Sendable {
    func fetch() async throws -> [ProviderUsageSnapshot]
    func fetch(providers: Set<AgentKind>) async throws -> [ProviderUsageSnapshot]
}

extension CLIUsageReading {
    func fetch(providers: Set<AgentKind>) async throws -> [ProviderUsageSnapshot] {
        try await fetch().filter { providers.contains($0.provider) }
    }
}

protocol ProviderQuotaReading: Sendable {
    func fetchObservation() async throws -> ProviderUsageObservation
}

actor CLIUsageService: CLIUsageReading {
    static let displayedKinds: [AgentKind] = [.codex, .claude, .grok, .cursor]

    private let readers: [AgentKind: any ProviderQuotaReading]
    private var lastGood: [AgentKind: [ProviderUsageWindowID: ProviderUsageWindow]] = [:]
    private var windowOrder: [AgentKind: [ProviderUsageWindowID]] = [:]

    init(readers: [AgentKind: any ProviderQuotaReading]) {
        self.readers = readers
    }

    func fetch() async throws -> [ProviderUsageSnapshot] {
        try await fetch(providers: Set(Self.displayedKinds))
    }

    func fetch(providers: Set<AgentKind>) async throws -> [ProviderUsageSnapshot] {
        let requestedKinds = Self.displayedKinds.filter { providers.contains($0) }
        let results = try await withThrowingTaskGroup(
            of: ProviderFetchResult.self,
            returning: [AgentKind: ProviderFetchResult].self
        ) { group in
            for kind in requestedKinds {
                guard let reader = readers[kind] else { continue }
                group.addTask {
                    do {
                        return .success(kind, try await reader.fetchObservation())
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .failure(kind, Self.failureReason(for: kind, error: error))
                    }
                }
            }

            var values: [AgentKind: ProviderFetchResult] = [:]
            for try await result in group {
                values[result.kind] = result
            }
            return values
        }

        try Task.checkCancellation()

        return requestedKinds.map { kind in
            switch results[kind] {
            case .success(_, let observation):
                merge(observation, for: kind)
            case .failure(_, let reason):
                staleSnapshot(for: kind, reason: reason)
            case nil:
                staleSnapshot(for: kind, reason: Self.failureReason(for: kind))
            }
        }
    }

    private func merge(
        _ observation: ProviderUsageObservation,
        for kind: AgentKind
    ) -> ProviderUsageSnapshot {
        var cached = lastGood[kind] ?? [:]
        var order: [ProviderUsageWindowID] = []
        var failureReasons: [String] = []

        for item in observation.windows where item.id.provider == kind {
            order.append(item.id)
            switch item {
            case .available(let value):
                let bounded = ProviderUsageWindowValue(
                    id: value.id,
                    label: value.label,
                    remainingPercent: min(max(value.remainingPercent, 0), 100),
                    resetsAt: value.resetsAt
                )
                cached[value.id] = ProviderUsageWindow(
                    value: bounded,
                    freshness: .fresh,
                    lastSuccessfulAt: observation.fetchedAt
                )
            case .failed(let id, let reason):
                failureReasons.append(reason)
                guard let previous = cached[id] else { continue }
                cached[id] = ProviderUsageWindow(
                    value: previous.value,
                    freshness: .stale(
                        reason: reason,
                        lastSuccessfulAt: previous.lastSuccessfulAt
                    ),
                    lastSuccessfulAt: previous.lastSuccessfulAt
                )
            case .removed(let id):
                cached[id] = nil
            }
        }

        for id in windowOrder[kind] ?? [] where !order.contains(id) && cached[id] != nil {
            let reason = "\(kind.displayName) \(id.key) quota was omitted from the latest response."
            let previous = cached[id]!
            cached[id] = ProviderUsageWindow(
                value: previous.value,
                freshness: .stale(
                    reason: reason,
                    lastSuccessfulAt: previous.lastSuccessfulAt
                ),
                lastSuccessfulAt: previous.lastSuccessfulAt
            )
            failureReasons.append(reason)
            order.append(id)
        }
        order.removeAll { cached[$0] == nil }
        lastGood[kind] = cached
        windowOrder[kind] = order
        let windows = order.compactMap { cached[$0] }
        let state: ProviderUsageSnapshotState
        if windows.contains(where: { $0.freshness == .fresh }) {
            state = .available
        } else if let staleReason = windows.compactMap(\.staleReason).first {
            state = .stale(reason: staleReason)
        } else if let failureReason = failureReasons.first {
            state = .unavailable(reason: failureReason)
        } else {
            state = .available
        }

        return ProviderUsageSnapshot(
            provider: kind,
            state: state,
            windows: windows,
            fetchedAt: observation.fetchedAt
        )
    }

    private func staleSnapshot(for kind: AgentKind, reason: String) -> ProviderUsageSnapshot {
        guard var cached = lastGood[kind], !cached.isEmpty else {
            return ProviderUsageSnapshot(
                provider: kind,
                state: .unavailable(reason: reason),
                windows: [],
                fetchedAt: nil
            )
        }

        for (id, previous) in cached {
            cached[id] = ProviderUsageWindow(
                value: previous.value,
                freshness: .stale(
                    reason: reason,
                    lastSuccessfulAt: previous.lastSuccessfulAt
                ),
                lastSuccessfulAt: previous.lastSuccessfulAt
            )
        }
        lastGood[kind] = cached
        let windows = (windowOrder[kind] ?? []).compactMap { cached[$0] }
        return ProviderUsageSnapshot(
            provider: kind,
            state: .stale(reason: reason),
            windows: windows,
            fetchedAt: windows.map(\.lastSuccessfulAt).max()
        )
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        permissionReporter: (any ProtectedFileAccessReporting)? = nil
    ) -> Self {
        let terminalEnvironment = TerminalEnvironment.make(
            base: environment,
            homeDirectory: homeDirectory
        )
        var claudeEnvironment = terminalEnvironment
        if claudeEnvironment["CLAUDE_CONFIG_DIR"]?.isEmpty != false {
            claudeEnvironment["CLAUDE_CONFIG_DIR"] = homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .path
        }
        let transport = URLSessionProviderUsageHTTPTransport()
        return Self(readers: [
            .codex: CodexUsageReader(
                executable: homeDirectory.appendingPathComponent(".local/bin/codex"),
                environment: terminalEnvironment
            ),
            .claude: ClaudeUsageReader(
                accessTokenLoader: ClaudeAccessTokenStore(
                    environment: environment,
                    homeDirectory: homeDirectory,
                    permissionReporter: permissionReporter
                ),
                transport: transport,
                cliExecutable: homeDirectory.appendingPathComponent(".local/bin/claude"),
                cliRunner: CLICommandRunner(environment: claudeEnvironment)
            ),
            .grok: GrokUsageReader(
                executable: homeDirectory.appendingPathComponent(".local/bin/grok"),
                environment: terminalEnvironment
            ),
            .cursor: CursorUsageReader(
                accessTokenLoader: CursorAccessTokenStore(
                    environment: environment,
                    homeDirectory: homeDirectory,
                    permissionReporter: permissionReporter
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

    private static func failureReason(for kind: AgentKind, error: any Error) -> String {
        if kind == .grok, let error = error as? GrokACPUsageError {
            switch error {
            case .methodNotFound: "Grok CLI does not support _x.ai/billing."
            case .authenticationRequired: "Grok billing requires CLI authentication."
            case .timedOut: "Grok billing refresh timed out."
            case .invalidResponse, .processEnded, .rpcFailure:
                failureReason(for: kind)
            }
        } else if kind == .codex, let error = error as? CLIUsageError, error == .timedOut {
            "Codex quota refresh timed out."
        } else if kind == .claude, let error = error as? ProviderUsageError,
                  error == .authenticationRequired {
            "Claude login expired; run /login in Claude Code."
        } else if let error = error as? ProviderUsageError,
                  error == .missingCredentials {
            "\(kind.displayName) credentials are unavailable."
        } else {
            failureReason(for: kind)
        }
    }
}

private extension ProviderUsageWindow {
    var staleReason: String? {
        guard case .stale(let reason, _) = freshness else { return nil }
        return reason
    }
}

private enum ProviderFetchResult: Sendable {
    case success(AgentKind, ProviderUsageObservation)
    case failure(AgentKind, String)

    var kind: AgentKind {
        switch self {
        case .success(let kind, _), .failure(let kind, _): kind
        }
    }
}
