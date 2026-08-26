import Foundation
import Testing
@testable import AgentGrid

struct CLIMaintenanceTests {
    @Test("Live plan checks for newer releases before selecting official updater commands")
    func livePlanCommands() throws {
        let home = URL(fileURLWithPath: "/home/test", isDirectory: true)
        let npm = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
        let executables: [AgentKind: URL] = [
            .codex: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"),
            .claude: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js"),
            .grok: home.appendingPathComponent(".grok/bin/grok"),
            .cursor: home.appendingPathComponent(".local/share/cursor-agent/current/cursor-agent"),
            .hermes: home.appendingPathComponent(".local/bin/hermes"),
        ]

        let plan = CLIMaintenancePlan.make(
            homeDirectory: home,
            npmExecutable: npm,
            executableForKind: { executables[$0] }
        )

        #expect(plan.items.map(\.kind) == [.codex, .claude, .grok, .cursor, .hermes])
        #expect(plan.items.map(\.aliasURL.path) == [
            "/home/test/.local/bin/codex",
            "/home/test/.local/bin/claude",
            "/home/test/.local/bin/grok",
            "/home/test/.local/bin/cursor-agent",
            "/home/test/.local/bin/hermes",
        ])
        #expect(plan.items.map(\.updateCheckFormat) == [
            .semanticVersion,
            .semanticVersion,
            .grokJSON,
            .selfInstalling,
            .hermesText,
        ])
        #expect(plan.items.map(\.checkCommand) == [
            CLICommand(
                executable: npm,
                arguments: ["view", "@openai/codex", "version", "--json"],
                timeout: .seconds(20),
                capturesOutput: true
            ),
            CLICommand(
                executable: npm,
                arguments: ["view", "@anthropic-ai/claude-code", "version", "--json"],
                timeout: .seconds(20),
                capturesOutput: true
            ),
            CLICommand(
                executable: try #require(executables[.grok]),
                arguments: ["update", "--check", "--json"],
                timeout: .seconds(20),
                capturesOutput: true
            ),
            CLICommand(
                executable: try #require(executables[.cursor]),
                arguments: ["update"],
                capturesOutput: true
            ),
            CLICommand(
                executable: try #require(executables[.hermes]),
                arguments: ["update", "--check"],
                timeout: .seconds(20),
                capturesOutput: true
            ),
        ])
        #expect(plan.items.map(\.updateCommand) == [
            CLICommand(executable: npm, arguments: ["install", "-g", "--no-audit", "--no-fund", "@openai/codex@latest"]),
            CLICommand(
                executable: npm,
                arguments: [
                    "install", "-g", "--no-audit", "--no-fund", "--foreground-scripts",
                    "--allow-scripts=@anthropic-ai/claude-code",
                    "@anthropic-ai/claude-code@latest",
                ]
            ),
            CLICommand(executable: try #require(executables[.grok]), arguments: ["update"]),
            nil,
            nil,
        ])
    }

    @Test("Hermes update availability warns without mutating a custom installation")
    func hermesUpdateAvailabilityIsNonMutating() async throws {
        let home = URL(fileURLWithPath: "/home/test", isDirectory: true)
        let executables = Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map { kind in
                (kind, URL(fileURLWithPath: "/tools/\(kind.executableName)"))
            }
        )
        let plan = CLIMaintenancePlan.make(
            homeDirectory: home,
            npmExecutable: nil,
            executableForKind: { executables[$0] }
        )
        let runner = HermesUpdatePolicyRunner()
        let service = CLIMaintenanceService(
            plan: plan,
            runner: runner,
            aliasStore: StubCLIAliasStore(repairFailures: [:], fallbackKinds: [])
        )

        let report = await service.perform()

        let commands = await runner.recordedCommands()
        #expect(!commands.contains { command in
            command.executable.lastPathComponent == "hermes"
                && command.arguments == ["update", "--yes"]
        })
        #expect(
            try #require(report.entries.first { $0.kind == .hermes }).state
                == .readyWithWarning(version: "1.0.0")
        )
        #expect(report.isLaunchable)
    }

    @Test("An up-to-date CLI is verified without running its updater")
    func upToDateSkipsUpdater() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "\"1.0.0\"\n")],
            updateOutcomes: [],
            verificationOutcomes: [.exited(status: 0, output: "codex-cli 1.0.0\n")],
            kinds: [.codex]
        )

        let report = await fixture.service.perform()

        let commands = await fixture.runner.recordedCommands()
        #expect(commands.filter { $0.executable.path.hasPrefix("/updates/") }.isEmpty)
        #expect(try #require(report.entries.first).state == .ready(version: "codex-cli 1.0.0"))
    }

    @Test("A newer available version runs exactly one updater and verifies the result")
    func newerVersionRunsUpdater() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "\"1.1.0\"\n")],
            updateOutcomes: [.exited(status: 0, output: "")],
            verificationOutcomes: [
                .exited(status: 0, output: "codex-cli 1.0.0\n"),
                .exited(status: 0, output: "codex-cli 1.1.0\n"),
            ],
            kinds: [.codex]
        )

        let report = await fixture.service.perform()

        let commands = await fixture.runner.recordedCommands()
        #expect(commands.filter { $0.executable.path.hasPrefix("/updates/") }.count == 1)
        #expect(try #require(report.entries.first).state == .ready(version: "codex-cli 1.1.0"))
    }

    @Test("Grok JSON update availability runs its updater")
    func grokUpdateAvailabilityRunsUpdater() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "{\"updateAvailable\":true}")],
            updateOutcomes: [.exited(status: 0, output: "")],
            verificationOutcomes: [
                .exited(status: 0, output: "grok 1.0.5"),
                .exited(status: 0, output: "grok 1.0.6"),
            ],
            kinds: [.grok]
        )

        let report = await fixture.service.perform()

        #expect(await fixture.runner.recordedCommands().filter {
            $0.executable.path.hasPrefix("/updates/")
        }.count == 1)
        #expect(try #require(report.entries.first).state == .ready(version: "grok 1.0.6"))
    }

    @Test("A failed version check never invokes the updater and keeps a verified alias")
    func failedCheckSkipsUpdater() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "unexpected response")],
            updateOutcomes: [],
            verificationOutcomes: [.exited(status: 0, output: "codex-cli 1.0.0")],
            kinds: [.codex]
        )

        let report = await fixture.service.perform()

        #expect(await fixture.runner.recordedCommands().filter {
            $0.executable.path.hasPrefix("/updates/")
        }.isEmpty)
        #expect(try #require(report.entries.first).state == .readyWithWarning(version: "codex-cli 1.0.0"))
    }

    @Test("A native self-checking updater is not invoked twice")
    func selfCheckingUpdaterRunsOnce() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "Already up to date")],
            updateOutcomes: [],
            verificationOutcomes: [
                .exited(status: 0, output: "2026.08.11"),
                .exited(status: 0, output: "2026.08.11"),
            ],
            kinds: [.cursor]
        )

        let report = await fixture.service.perform()
        let commands = await fixture.runner.recordedCommands()

        #expect(commands.filter { $0.executable.path.hasPrefix("/checks/") }.count == 1)
        #expect(commands.filter { $0.executable.path.hasPrefix("/updates/") }.isEmpty)
        #expect(try #require(report.entries.first).state == .ready(version: "2026.08.11"))
    }

    @Test("A failed update is a warning when the canonical alias verifies")
    func verifiedFallbackIsWarning() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "\"1.1.0\"\n")],
            updateOutcomes: [.exited(status: 7, output: "")],
            verificationOutcomes: [
                .exited(status: 0, output: "codex-cli 1.0.0\n"),
                .exited(status: 0, output: "codex-cli 1.0.0\n"),
            ],
            kinds: [.codex]
        )

        let report = await fixture.service.perform()
        let entry = try #require(report.entries.first)

        #expect(entry.state == .readyWithWarning(version: "codex-cli 1.0.0"))
        #expect(!report.isLaunchable)
    }

    @Test("A broken canonical alias blocks terminal launch")
    func brokenAliasBlocksLaunch() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "Already up to date\n")],
            updateOutcomes: [.exited(status: 0, output: "")],
            verificationOutcomes: [.exited(status: 1, output: "")],
            kinds: [.claude]
        )

        let report = await fixture.service.perform()
        let entry = try #require(report.entries.first)

        #expect(entry.state == .failed(reason: "Claude alias did not pass --version"))
        #expect(!report.isLaunchable)
    }

    @Test("Alias repair failure blocks verification without hiding later CLIs")
    func repairFailureStillContinues() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [
                .exited(status: 0, output: "\"1.0.0\""),
                .exited(status: 0, output: "{\"updateAvailable\":false}"),
            ],
            updateOutcomes: [
                .exited(status: 0, output: ""),
                .exited(status: 0, output: ""),
            ],
            verificationOutcomes: [.exited(status: 0, output: "2.0\n")],
            kinds: [.codex, .grok],
            repairFailures: [.codex: .noExecutable]
        )

        let report = await fixture.service.perform()

        #expect(report.entries.map(\.kind) == [.codex, .grok])
        #expect(report.entries[0].state == .failed(reason: "Codex executable could not be resolved"))
        #expect(report.entries[1].state == .ready(version: "2.0"))
        #expect(!report.isLaunchable)
    }

    @Test("Progress reports each active CLI and one completed terminal state")
    func reportsOrderedProgress() async {
        let fixture = MaintenanceFixture(
            checkOutcomes: [
                .exited(status: 0, output: "\"1.0.0\""),
                .exited(status: 0, output: "\"1.0.0\""),
                .exited(status: 0, output: "{\"updateAvailable\":false}"),
                .exited(status: 0, output: "Already up to date"),
                .exited(status: 0, output: "Up to date"),
            ],
            updateOutcomes: Array(repeating: .exited(status: 0, output: ""), count: 5),
            verificationOutcomes: Array(
                repeating: .exited(status: 0, output: "1.0\n"),
                count: 6
            )
        )
        let recorder = ProgressRecorder()

        _ = await fixture.service.perform { progress in
            await recorder.append(progress)
        }

        let values = await recorder.values
        #expect(values.first?.stage == .checking)
        #expect(values.last?.activeKind == nil)
        #expect(values.last?.completedCount == 5)
        #expect(values.last?.entries.map(\.kind) == AgentKind.allCases)
    }

    @Test("A partial or duplicate report cannot satisfy the all-CLI launch gate")
    func rejectsIncompleteReports() {
        let partial = CLIMaintenanceReport(entries: [
            CLIMaintenanceEntry(kind: .codex, state: .ready(version: "1.0")),
        ])
        let duplicates = CLIMaintenanceReport(
            entries: Array(
                repeating: CLIMaintenanceEntry(
                    kind: .codex,
                    state: .ready(version: "1.0")
                ),
                count: AgentKind.allCases.count
            )
        )

        #expect(!partial.isLaunchable)
        #expect(!duplicates.isLaunchable)
    }

    @Test("A pre-cancelled maintenance pass starts no updater")
    func preCancelledPassStartsNothing() async {
        let fixture = MaintenanceFixture(
            checkOutcomes: Array(repeating: .exited(status: 0, output: "Up to date"), count: 5),
            updateOutcomes: Array(repeating: .exited(status: 0, output: ""), count: 5),
            verificationOutcomes: Array(
                repeating: .exited(status: 0, output: "1.0"),
                count: 5
            )
        )
        let task = Task {
            await Task.yield()
            return await fixture.service.perform()
        }

        task.cancel()
        let report = await task.value

        #expect(report.entries.isEmpty)
        #expect(await fixture.runner.recordedCommands().isEmpty)
    }

    @Test("A retained fallback is a warning even when the updater exits zero")
    func retainedFallbackWarnsAfterSuccessfulUpdater() async throws {
        let fixture = MaintenanceFixture(
            checkOutcomes: [.exited(status: 0, output: "\"1.1.0\"")],
            updateOutcomes: [.exited(status: 0, output: "")],
            verificationOutcomes: [
                .exited(status: 0, output: "codex-cli 1.0.0"),
                .exited(status: 0, output: "codex-cli 1.1.0"),
            ],
            kinds: [.codex],
            fallbackKinds: [.codex]
        )

        let report = await fixture.service.perform()
        let entry = try #require(report.entries.first)

        #expect(entry.state == .readyWithWarning(version: "codex-cli 1.1.0"))
    }
}

private actor ProgressRecorder {
    private(set) var values: [CLIMaintenanceProgress] = []

    func append(_ value: CLIMaintenanceProgress) {
        values.append(value)
    }
}

private actor HermesUpdatePolicyRunner: CLICommandRunning {
    private var commands: [CLICommand] = []

    func run(_ command: CLICommand) -> CLICommandOutcome {
        commands.append(command)
        return switch command.arguments {
        case ["--version"]:
            .exited(status: 0, output: "1.0.0")
        case ["update", "--check", "--json"]:
            .exited(status: 0, output: #"{"updateAvailable":false}"#)
        case ["update", "--check"]:
            .exited(status: 0, output: "Update available")
        case ["update", "--yes"]:
            .exited(status: 1, output: "Updater must not run")
        case ["update"]:
            .exited(status: 0, output: "Already up to date")
        default:
            .failedToStart("Unexpected command")
        }
    }

    func recordedCommands() -> [CLICommand] {
        commands
    }
}

private struct MaintenanceFixture {
    let runner: StubCLICommandRunner
    let aliasStore: StubCLIAliasStore
    let service: CLIMaintenanceService

    init(
        checkOutcomes: [CLICommandOutcome],
        updateOutcomes: [CLICommandOutcome],
        verificationOutcomes: [CLICommandOutcome],
        kinds: [AgentKind] = AgentKind.allCases,
        repairFailures: [AgentKind: CLIAliasError] = [:],
        fallbackKinds: Set<AgentKind> = []
    ) {
        let runner = StubCLICommandRunner(
            checkOutcomes: checkOutcomes,
            updateOutcomes: updateOutcomes,
            verificationOutcomes: verificationOutcomes
        )
        let aliasStore = StubCLIAliasStore(
            repairFailures: repairFailures,
            fallbackKinds: fallbackKinds
        )
        let items = kinds.map { kind in
            let checkFormat: CLIUpdateCheckFormat = switch kind {
            case .codex, .claude: .semanticVersion
            case .grok: .grokJSON
            case .cursor: .selfInstalling
            case .hermes: .hermesText
            }
            return CLIMaintenanceItem(
                kind: kind,
                aliasURL: URL(fileURLWithPath: "/aliases/\(kind.executableName)"),
                checkCommand: CLICommand(
                    executable: URL(fileURLWithPath: "/checks/\(kind.executableName)"),
                    arguments: ["check"],
                    timeout: .seconds(20),
                    capturesOutput: true
                ),
                updateCommand: CLICommand(
                    executable: URL(fileURLWithPath: "/updates/\(kind.executableName)"),
                    arguments: ["update"]
                ),
                updateCheckFormat: checkFormat
            )
        }

        self.runner = runner
        self.aliasStore = aliasStore
        service = CLIMaintenanceService(
            plan: CLIMaintenancePlan(items: items),
            runner: runner,
            aliasStore: aliasStore
        )
    }
}

private actor StubCLICommandRunner: CLICommandRunning {
    private var checks: [CLICommandOutcome]
    private var updates: [CLICommandOutcome]
    private var verifications: [CLICommandOutcome]
    private var commands: [CLICommand] = []

    init(
        checkOutcomes: [CLICommandOutcome],
        updateOutcomes: [CLICommandOutcome],
        verificationOutcomes: [CLICommandOutcome]
    ) {
        checks = checkOutcomes
        updates = updateOutcomes
        verifications = verificationOutcomes
    }

    func run(_ command: CLICommand) async -> CLICommandOutcome {
        commands.append(command)
        if command.arguments == ["--version"] {
            return verifications.isEmpty
                ? .failedToStart("Missing verification fixture")
                : verifications.removeFirst()
        }
        if command.executable.path.hasPrefix("/checks/") {
            return checks.isEmpty
                ? .failedToStart("Missing update-check fixture")
                : checks.removeFirst()
        }
        return updates.isEmpty
            ? .failedToStart("Missing update fixture")
            : updates.removeFirst()
    }

    func recordedCommands() -> [CLICommand] {
        commands
    }
}

private actor StubCLIAliasStore: CLIAliasMaintaining {
    private let repairFailures: [AgentKind: CLIAliasError]
    private let fallbackKinds: Set<AgentKind>

    init(
        repairFailures: [AgentKind: CLIAliasError],
        fallbackKinds: Set<AgentKind>
    ) {
        self.repairFailures = repairFailures
        self.fallbackKinds = fallbackKinds
    }

    func repairAlias(for item: CLIMaintenanceItem) async throws -> CLIAliasRepair {
        if let error = repairFailures[item.kind] {
            throw error
        }
        return CLIAliasRepair(
            aliasURL: item.aliasURL,
            usedFallback: fallbackKinds.contains(item.kind)
        )
    }
}
