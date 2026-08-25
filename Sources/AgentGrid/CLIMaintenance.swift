import Foundation

struct CLICommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let timeout: Duration
    let capturesOutput: Bool

    init(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(120),
        capturesOutput: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.capturesOutput = capturesOutput
    }
}

enum CLICommandOutcome: Equatable, Sendable {
    case exited(status: Int32, output: String)
    case timedOut
    case cancelled
    case failedToStart(String)

    var succeeded: Bool {
        if case .exited(status: 0, output: _) = self {
            return true
        }
        return false
    }
}

protocol CLICommandRunning: Sendable {
    func run(_ command: CLICommand) async -> CLICommandOutcome
}

enum CLIAliasError: Error, Equatable, Sendable {
    case noExecutable
    case destinationIsDirectory
    case selfReferentialTarget
    case fileSystem(String)
}

protocol CLIAliasMaintaining: Sendable {
    func repairAlias(for item: CLIMaintenanceItem) async throws -> URL
}

protocol CLIMaintaining: Sendable {
    func perform(
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void
    ) async -> CLIMaintenanceReport
}

struct CLIMaintenanceItem: Equatable, Sendable {
    let kind: AgentKind
    let aliasURL: URL
    let updateCommand: CLICommand?
}

struct CLIMaintenancePlan: Equatable, Sendable {
    let items: [CLIMaintenanceItem]

    static func make(
        homeDirectory: URL,
        npmExecutable: URL?,
        executableForKind: @Sendable (AgentKind) -> URL?
    ) -> Self {
        let aliasDirectory = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let items = AgentKind.allCases.map { kind in
            let executable = executableForKind(kind)
            return CLIMaintenanceItem(
                kind: kind,
                aliasURL: aliasDirectory.appendingPathComponent(
                    kind.executableName,
                    isDirectory: false
                ),
                updateCommand: updateCommand(
                    for: kind,
                    executable: executable,
                    npmExecutable: npmExecutable
                )
            )
        }
        return Self(items: items)
    }

    private static func updateCommand(
        for kind: AgentKind,
        executable: URL?,
        npmExecutable: URL?
    ) -> CLICommand? {
        if let npmExecutable,
           let package = npmPackage(for: kind),
           executable?.resolvingSymlinksInPath().path.contains("/node_modules/") == true {
            var arguments = ["install", "-g", "--no-audit", "--no-fund"]
            if kind == .claude {
                arguments += [
                    "--foreground-scripts",
                    "--allow-scripts=@anthropic-ai/claude-code",
                ]
            }
            arguments.append("\(package)@latest")
            return CLICommand(
                executable: npmExecutable,
                arguments: arguments
            )
        }

        guard let executable else { return nil }
        let arguments = kind == .hermes ? ["update", "--yes"] : ["update"]
        return CLICommand(executable: executable, arguments: arguments)
    }

    private static func npmPackage(for kind: AgentKind) -> String? {
        switch kind {
        case .codex: "@openai/codex"
        case .claude: "@anthropic-ai/claude-code"
        case .grok, .cursor, .hermes: nil
        }
    }
}

enum CLIMaintenanceEntryState: Equatable, Sendable {
    case ready(version: String)
    case readyWithWarning(version: String)
    case failed(reason: String)

    var isReady: Bool {
        switch self {
        case .ready, .readyWithWarning: true
        case .failed: false
        }
    }
}

struct CLIMaintenanceEntry: Equatable, Sendable {
    let kind: AgentKind
    let state: CLIMaintenanceEntryState
}

struct CLIMaintenanceReport: Equatable, Sendable {
    let entries: [CLIMaintenanceEntry]

    var isLaunchable: Bool {
        entries.count == AgentKind.allCases.count
            && Set(entries.map(\.kind)) == Set(AgentKind.allCases)
            && entries.allSatisfy { $0.state.isReady }
    }

    var warnings: [AgentKind] {
        entries.compactMap { entry in
            if case .readyWithWarning = entry.state {
                return entry.kind
            }
            return nil
        }
    }
}

struct CLIMaintenanceProgress: Equatable, Sendable {
    let completedCount: Int
    let activeKind: AgentKind?
    let entries: [CLIMaintenanceEntry]
}

struct CLIMaintenanceService: Sendable {
    let plan: CLIMaintenancePlan
    let runner: any CLICommandRunning
    let aliasStore: any CLIAliasMaintaining

    func perform(
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void = { _ in }
    ) async -> CLIMaintenanceReport {
        var entries: [CLIMaintenanceEntry] = []

        for item in plan.items {
            await progress(
                CLIMaintenanceProgress(
                    completedCount: entries.count,
                    activeKind: item.kind,
                    entries: entries
                )
            )

            let updateOutcome = if let updateCommand = item.updateCommand {
                await runner.run(updateCommand)
            } else {
                CLICommandOutcome.failedToStart("Updater executable could not be resolved")
            }

            let entry: CLIMaintenanceEntry
            do {
                let aliasURL = try await aliasStore.repairAlias(for: item)
                let verification = await runner.run(
                    CLICommand(
                        executable: aliasURL,
                        arguments: ["--version"],
                        timeout: .seconds(20),
                        capturesOutput: true
                    )
                )

                if case let .exited(status: 0, output: output) = verification {
                    let version = normalizedVersion(output)
                    entry = CLIMaintenanceEntry(
                        kind: item.kind,
                        state: updateOutcome.succeeded
                            ? .ready(version: version)
                            : .readyWithWarning(version: version)
                    )
                } else {
                    entry = CLIMaintenanceEntry(
                        kind: item.kind,
                        state: .failed(
                            reason: "\(item.kind.displayName.replacingOccurrences(of: " Agent", with: "")) alias did not pass --version"
                        )
                    )
                }
            } catch let error as CLIAliasError {
                entry = CLIMaintenanceEntry(
                    kind: item.kind,
                    state: .failed(reason: aliasFailureReason(error, kind: item.kind))
                )
            } catch {
                entry = CLIMaintenanceEntry(
                    kind: item.kind,
                    state: .failed(reason: "\(item.kind.displayName) alias could not be repaired")
                )
            }

            entries.append(entry)
        }

        await progress(
            CLIMaintenanceProgress(
                completedCount: entries.count,
                activeKind: nil,
                entries: entries
            )
        )
        return CLIMaintenanceReport(entries: entries)
    }

    private func normalizedVersion(_ output: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Verified" : value
    }

    private func aliasFailureReason(_ error: CLIAliasError, kind: AgentKind) -> String {
        switch error {
        case .noExecutable:
            "\(kind.displayName) executable could not be resolved"
        case .destinationIsDirectory:
            "\(kind.displayName) alias path is a directory"
        case .selfReferentialTarget:
            "\(kind.displayName) alias target is self-referential"
        case .fileSystem:
            "\(kind.displayName) alias could not be repaired"
        }
    }
}

extension CLIMaintenanceService: CLIMaintaining {
    static func live(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let environment = TerminalEnvironment.make(
            base: baseEnvironment,
            homeDirectory: homeDirectory
        )
        let resolver = BinaryResolver(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let cliLocator = CLIExecutableLocator(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let plan = CLIMaintenancePlan.make(
            homeDirectory: homeDirectory,
            npmExecutable: resolver.resolve("npm"),
            executableForKind: { cliLocator.locate($0) }
        )
        return Self(
            plan: plan,
            runner: CLICommandRunner(environment: environment),
            aliasStore: CanonicalCLIAliasStore(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )
    }
}
