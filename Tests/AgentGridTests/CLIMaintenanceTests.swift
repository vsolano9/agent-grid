import Foundation
import Testing
@testable import AgentGrid

struct CLIMaintenanceTests {
    @Test("Live plan uses exact official updater commands in catalog order")
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
            CLICommand(executable: try #require(executables[.cursor]), arguments: ["update"]),
            CLICommand(executable: try #require(executables[.hermes]), arguments: ["update", "--yes"]),
        ])
    }

    @Test("Maintenance attempts every updater after an earlier failure")
    func attemptsEveryUpdater() async throws {
        let fixture = MaintenanceFixture(
            updateOutcomes: [
                .exited(status: 1, output: ""),
                .exited(status: 0, output: ""),
                .exited(status: 0, output: ""),
                .exited(status: 0, output: ""),
            ],
            verificationOutcomes: Array(
                repeating: .exited(status: 0, output: "1.0\n"),
                count: 5
            )
        )

        let report = await fixture.service.perform()

        #expect(await fixture.runner.recordedCommands().filter { $0.arguments.first != "--version" }.count == 5)
        #expect(report.entries.count == 5)
        #expect(report.isLaunchable)
    }

    @Test("A failed update is a warning when the canonical alias verifies")
    func verifiedFallbackIsWarning() async throws {
        let fixture = MaintenanceFixture(
            updateOutcomes: [.exited(status: 7, output: "")],
            verificationOutcomes: [.exited(status: 0, output: "codex-cli 1.0\n")],
            kinds: [.codex]
        )

        let report = await fixture.service.perform()
        let entry = try #require(report.entries.first)

        #expect(entry.state == .readyWithWarning(version: "codex-cli 1.0"))
        #expect(!report.isLaunchable)
    }

    @Test("A broken canonical alias blocks terminal launch")
    func brokenAliasBlocksLaunch() async throws {
        let fixture = MaintenanceFixture(
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
            updateOutcomes: Array(repeating: .exited(status: 0, output: ""), count: 5),
            verificationOutcomes: Array(
                repeating: .exited(status: 0, output: "1.0\n"),
                count: 5
            )
        )
        let recorder = ProgressRecorder()

        _ = await fixture.service.perform { progress in
            await recorder.append(progress)
        }

        let values = await recorder.values
        #expect(values.map(\.activeKind) == [.codex, .claude, .grok, .cursor, .hermes, nil])
        #expect(values.map(\.completedCount) == [0, 1, 2, 3, 4, 5])
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
            updateOutcomes: [.exited(status: 0, output: "")],
            verificationOutcomes: [.exited(status: 0, output: "codex-cli 1.0")],
            kinds: [.codex],
            fallbackKinds: [.codex]
        )

        let report = await fixture.service.perform()
        let entry = try #require(report.entries.first)

        #expect(entry.state == .readyWithWarning(version: "codex-cli 1.0"))
    }
}

private actor ProgressRecorder {
    private(set) var values: [CLIMaintenanceProgress] = []

    func append(_ value: CLIMaintenanceProgress) {
        values.append(value)
    }
}

private struct MaintenanceFixture {
    let runner: StubCLICommandRunner
    let aliasStore: StubCLIAliasStore
    let service: CLIMaintenanceService

    init(
        updateOutcomes: [CLICommandOutcome],
        verificationOutcomes: [CLICommandOutcome],
        kinds: [AgentKind] = AgentKind.allCases,
        repairFailures: [AgentKind: CLIAliasError] = [:],
        fallbackKinds: Set<AgentKind> = []
    ) {
        let runner = StubCLICommandRunner(
            updateOutcomes: updateOutcomes,
            verificationOutcomes: verificationOutcomes
        )
        let aliasStore = StubCLIAliasStore(
            repairFailures: repairFailures,
            fallbackKinds: fallbackKinds
        )
        let items = kinds.map { kind in
            CLIMaintenanceItem(
                kind: kind,
                aliasURL: URL(fileURLWithPath: "/aliases/\(kind.executableName)"),
                updateCommand: CLICommand(
                    executable: URL(fileURLWithPath: "/updates/\(kind.executableName)"),
                    arguments: ["update"]
                )
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
    private var updates: [CLICommandOutcome]
    private var verifications: [CLICommandOutcome]
    private var commands: [CLICommand] = []

    init(
        updateOutcomes: [CLICommandOutcome],
        verificationOutcomes: [CLICommandOutcome]
    ) {
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
