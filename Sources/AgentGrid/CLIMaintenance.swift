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
    case verificationFailed
    case destinationIsDirectory
    case selfReferentialTarget
    case fileSystem(String)
}

protocol CLIAliasMaintaining: Sendable {
    func repairAlias(for item: CLIMaintenanceItem) async throws -> CLIAliasRepair
}

struct CLIAliasRepair: Equatable, Sendable {
    let aliasURL: URL
    let usedFallback: Bool
}

protocol CLIMaintaining: Sendable {
    func perform(
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void
    ) async -> CLIMaintenanceReport
}

struct CLIMaintenanceItem: Equatable, Sendable {
    let kind: AgentKind
    let aliasURL: URL
    let checkCommand: CLICommand?
    let updateCommand: CLICommand?
    let updateCheckFormat: CLIUpdateCheckFormat

    init(
        kind: AgentKind,
        aliasURL: URL,
        checkCommand: CLICommand? = nil,
        updateCommand: CLICommand? = nil,
        updateCheckFormat: CLIUpdateCheckFormat = .semanticVersion
    ) {
        self.kind = kind
        self.aliasURL = aliasURL
        self.checkCommand = checkCommand
        self.updateCommand = updateCommand
        self.updateCheckFormat = updateCheckFormat
    }
}

enum CLIUpdateCheckFormat: Equatable, Sendable {
    case semanticVersion
    case grokJSON
    case hermesText
    case selfInstalling
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
                checkCommand: checkCommand(
                    for: kind,
                    executable: executable,
                    npmExecutable: npmExecutable
                ),
                updateCommand: updateCommand(
                    for: kind,
                    executable: executable,
                    npmExecutable: npmExecutable
                ),
                updateCheckFormat: updateCheckFormat(
                    for: kind,
                    npmExecutable: npmExecutable
                )
            )
        }
        return Self(items: items)
    }

    private static func checkCommand(
        for kind: AgentKind,
        executable: URL?,
        npmExecutable: URL?
    ) -> CLICommand? {
        if let npmExecutable, let package = npmPackage(for: kind) {
            return CLICommand(
                executable: npmExecutable,
                arguments: ["view", package, "version", "--json"],
                timeout: .seconds(20),
                capturesOutput: true
            )
        }

        guard let executable else { return nil }
        let arguments: [String]
        switch kind {
        case .codex, .claude, .cursor:
            arguments = ["update"]
        case .grok:
            arguments = ["update", "--check", "--json"]
        case .hermes:
            arguments = ["update", "--check"]
        }
        return CLICommand(
            executable: executable,
            arguments: arguments,
            timeout: kind == .cursor ? .seconds(120) : .seconds(20),
            capturesOutput: true
        )
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

        guard let executable, kind != .cursor else { return nil }
        if npmExecutable == nil, (kind == .codex || kind == .claude) {
            return nil
        }
        let arguments = kind == .hermes ? ["update", "--yes"] : ["update"]
        return CLICommand(executable: executable, arguments: arguments)
    }

    private static func updateCheckFormat(
        for kind: AgentKind,
        npmExecutable: URL?
    ) -> CLIUpdateCheckFormat {
        switch kind {
        case .codex, .claude:
            npmExecutable == nil ? .selfInstalling : .semanticVersion
        case .grok:
            .grokJSON
        case .cursor:
            .selfInstalling
        case .hermes:
            .hermesText
        }
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
    let stage: CLIMaintenanceStage?
    let entries: [CLIMaintenanceEntry]
}

enum CLIMaintenanceStage: Equatable, Sendable {
    case checking
    case updating
    case verifying
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
            if Task.isCancelled { break }
            await reportProgress(.checking, item: item, entries: entries, progress: progress)

            var verification = await verifyAlias(for: item)
            let currentVersion = verification.value?.version
            let checkOutcome = if let checkCommand = item.checkCommand {
                await runner.run(checkCommand)
            } else {
                CLICommandOutcome.failedToStart("Update check executable could not be resolved")
            }
            let decision = updateDecision(
                from: checkOutcome,
                format: item.updateCheckFormat,
                currentVersion: currentVersion
            )

            let maintenanceSucceeded: Bool
            switch decision {
            case .upToDate:
                maintenanceSucceeded = true
            case .selfInstalled:
                maintenanceSucceeded = checkOutcome.succeeded
                await reportProgress(.verifying, item: item, entries: entries, progress: progress)
                verification = await verifyAlias(for: item)
            case .updateAvailable:
                await reportProgress(.updating, item: item, entries: entries, progress: progress)
                let updateOutcome = if let updateCommand = item.updateCommand {
                    await runner.run(updateCommand)
                } else {
                    CLICommandOutcome.failedToStart("Updater executable could not be resolved")
                }
                maintenanceSucceeded = updateOutcome.succeeded
                await reportProgress(.verifying, item: item, entries: entries, progress: progress)
                verification = await verifyAlias(for: item)
            case .checkFailed:
                maintenanceSucceeded = false
            }

            let entry = entry(
                for: item,
                verification: verification,
                maintenanceSucceeded: maintenanceSucceeded
            )

            entries.append(entry)
        }

        await progress(
            CLIMaintenanceProgress(
                completedCount: entries.count,
                activeKind: nil,
                stage: nil,
                entries: entries
            )
        )
        return CLIMaintenanceReport(entries: entries)
    }

    private func reportProgress(
        _ stage: CLIMaintenanceStage,
        item: CLIMaintenanceItem,
        entries: [CLIMaintenanceEntry],
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void
    ) async {
        await progress(
            CLIMaintenanceProgress(
                completedCount: entries.count,
                activeKind: item.kind,
                stage: stage,
                entries: entries
            )
        )
    }

    private func verifyAlias(for item: CLIMaintenanceItem) async -> AliasVerificationResult {
        do {
            let repair = try await aliasStore.repairAlias(for: item)
            let outcome = await runner.run(
                CLICommand(
                    executable: repair.aliasURL,
                    arguments: ["--version"],
                    timeout: .seconds(20),
                    capturesOutput: true
                )
            )
            guard case let .exited(status: 0, output: output) = outcome else {
                return .failure(.verificationFailed)
            }
            return .success(
                VerifiedAlias(
                    version: normalizedVersion(output),
                    usedFallback: repair.usedFallback
                )
            )
        } catch let error as CLIAliasError {
            return .failure(error)
        } catch {
            return .failure(.fileSystem(error.localizedDescription))
        }
    }

    private func entry(
        for item: CLIMaintenanceItem,
        verification: AliasVerificationResult,
        maintenanceSucceeded: Bool
    ) -> CLIMaintenanceEntry {
        switch verification {
        case let .success(alias):
            return CLIMaintenanceEntry(
                kind: item.kind,
                state: maintenanceSucceeded && !alias.usedFallback
                    ? .ready(version: alias.version)
                    : .readyWithWarning(version: alias.version)
            )
        case let .failure(error):
            return CLIMaintenanceEntry(
                kind: item.kind,
                state: .failed(reason: aliasFailureReason(error, kind: item.kind))
            )
        }
    }

    private func updateDecision(
        from outcome: CLICommandOutcome,
        format: CLIUpdateCheckFormat,
        currentVersion: String?
    ) -> CLIUpdateDecision {
        guard case let .exited(status: 0, output: output) = outcome else {
            return .checkFailed
        }

        switch format {
        case .semanticVersion:
            guard let currentVersion,
                  let current = semanticVersion(in: currentVersion),
                  let latest = semanticVersion(in: output) else {
                return .checkFailed
            }
            return latest.lexicographicallyPrecedes(current) || latest == current
                ? .upToDate
                : .updateAvailable
        case .grokJSON:
            guard let data = output.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(GrokUpdateCheck.self, from: data) else {
                return .checkFailed
            }
            return payload.updateAvailable ? .updateAvailable : .upToDate
        case .hermesText:
            let normalized = output.lowercased()
            if normalized.contains("update available") { return .updateAvailable }
            if normalized.contains("up to date") || normalized.contains("up-to-date") {
                return .upToDate
            }
            return .checkFailed
        case .selfInstalling:
            return .selfInstalled
        }
    }

    private func semanticVersion(in value: String) -> [Int]? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])v?([0-9]+)\.([0-9]+)\.([0-9]+)"#
        ), let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) else {
            return nil
        }

        return (1...3).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
    }

    private func normalizedVersion(_ output: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Verified" : value
    }

    private func aliasFailureReason(_ error: CLIAliasError, kind: AgentKind) -> String {
        switch error {
        case .noExecutable:
            "\(kind.displayName) executable could not be resolved"
        case .verificationFailed:
            "\(kind.displayName.replacingOccurrences(of: " Agent", with: "")) alias did not pass --version"
        case .destinationIsDirectory:
            "\(kind.displayName) alias path is a directory"
        case .selfReferentialTarget:
            "\(kind.displayName) alias target is self-referential"
        case .fileSystem:
            "\(kind.displayName) alias could not be repaired"
        }
    }
}

private enum CLIUpdateDecision {
    case upToDate
    case updateAvailable
    case selfInstalled
    case checkFailed
}

private struct GrokUpdateCheck: Decodable {
    let updateAvailable: Bool
}

private struct VerifiedAlias {
    let version: String
    let usedFallback: Bool
}

private enum AliasVerificationResult {
    case success(VerifiedAlias)
    case failure(CLIAliasError)

    var value: VerifiedAlias? {
        guard case let .success(value) = self else { return nil }
        return value
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
        var maintenanceEnvironment = environment
        maintenanceEnvironment.removeValue(forKey: "PYTHONHOME")
        maintenanceEnvironment.removeValue(forKey: "PYTHONPATH")
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
        let runner = CLICommandRunner(environment: maintenanceEnvironment)
        return Self(
            plan: plan,
            runner: runner,
            aliasStore: CanonicalCLIAliasStore(
                homeDirectory: homeDirectory,
                environment: environment,
                verifiesExecutable: { executable in
                    await runner.run(
                        CLICommand(
                            executable: executable,
                            arguments: ["--version"],
                            timeout: .seconds(20),
                            capturesOutput: true
                        )
                    ).succeeded
                }
            )
        )
    }
}
