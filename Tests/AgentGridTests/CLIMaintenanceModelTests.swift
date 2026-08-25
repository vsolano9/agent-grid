import Foundation
import Testing
@testable import AgentGrid

@MainActor
struct CLIMaintenanceModelTests {
    @Test("Model starts idle and becomes ready only after a launchable report")
    func launchableReport() async {
        let service = StubCLIMaintenanceService(reports: [.allReady])
        let model = CLIMaintenanceModel(
            service: service,
            configurationFactory: { .testValue }
        )

        #expect(model.phase == .idle)
        #expect(model.configuration == nil)

        await model.start()

        #expect(model.phase == .ready(.allReady))
        #expect(model.configuration != nil)
        #expect(await service.callCount == 1)
    }

    @Test("Model exposes service progress while maintenance is active")
    func activeProgress() async {
        let service = GatedCLIMaintenanceService(report: .allReady)
        let model = CLIMaintenanceModel(
            service: service,
            configurationFactory: { .testValue }
        )
        let task = Task { await model.start() }

        await service.waitUntilPaused()

        #expect(model.phase == .running(
            CLIMaintenanceProgress(
                completedCount: 1,
                activeKind: .claude,
                stage: .checking,
                entries: [CLIMaintenanceReport.allReady.entries[0]]
            )
        ))
        #expect(model.configuration == nil)

        await service.resume()
        await task.value
        #expect(model.phase == .ready(.allReady))
    }

    @Test("Warning reports remain launchable and available to the workspace")
    func warningReport() async {
        let report = CLIMaintenanceReport(
            entries: AgentKind.allCases.map { kind in
                CLIMaintenanceEntry(
                    kind: kind,
                    state: kind == .codex
                        ? .readyWithWarning(version: "1.0")
                        : .ready(version: "1.0")
                )
            }
        )
        let model = CLIMaintenanceModel(
            service: StubCLIMaintenanceService(reports: [report]),
            configurationFactory: { .testValue }
        )

        await model.start()

        #expect(model.phase == .ready(report))
        #expect(model.warningKinds == [.codex])
        #expect(model.configuration != nil)
    }

    @Test("Broken aliases keep configuration unavailable")
    func failedReport() async {
        let report = CLIMaintenanceReport(entries: [
            CLIMaintenanceEntry(kind: .claude, state: .failed(reason: "broken")),
        ])
        let model = CLIMaintenanceModel(
            service: StubCLIMaintenanceService(reports: [report]),
            configurationFactory: { .testValue }
        )

        await model.start()

        #expect(model.phase == .failed(report))
        #expect(model.configuration == nil)
    }

    @Test("Retry performs a fresh complete maintenance pass")
    func retry() async {
        let failed = CLIMaintenanceReport(entries: [
            CLIMaintenanceEntry(kind: .grok, state: .failed(reason: "broken")),
        ])
        let service = StubCLIMaintenanceService(reports: [failed, .allReady])
        let model = CLIMaintenanceModel(
            service: service,
            configurationFactory: { .testValue }
        )

        await model.start()
        #expect(model.phase == .failed(failed))

        await model.retry()

        #expect(model.phase == .ready(.allReady))
        #expect(model.configuration != nil)
        #expect(await service.callCount == 2)
    }

    @Test("Cancellation returns to idle and a later start can complete")
    func cancellationCanRestart() async {
        let service = GatedCLIMaintenanceService(report: .allReady)
        let model = CLIMaintenanceModel(
            service: service,
            configurationFactory: { .testValue }
        )
        let first = Task { await model.start() }
        await service.waitUntilPaused()

        first.cancel()
        await service.resume()
        await first.value

        #expect(model.phase == .idle)
        #expect(model.configuration == nil)

        await model.start()
        #expect(model.phase == .ready(.allReady))
    }
}

private actor StubCLIMaintenanceService: CLIMaintaining {
    private var reports: [CLIMaintenanceReport]
    private(set) var callCount = 0

    init(reports: [CLIMaintenanceReport]) {
        self.reports = reports
    }

    func perform(
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void
    ) async -> CLIMaintenanceReport {
        callCount += 1
        return reports.removeFirst()
    }
}

private actor GatedCLIMaintenanceService: CLIMaintaining {
    private let report: CLIMaintenanceReport
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasPaused = false

    init(report: CLIMaintenanceReport) {
        self.report = report
    }

    func perform(
        progress: @escaping @Sendable (CLIMaintenanceProgress) async -> Void
    ) async -> CLIMaintenanceReport {
        await progress(
            CLIMaintenanceProgress(
                completedCount: 1,
                activeKind: .claude,
                stage: .checking,
                entries: [report.entries[0]]
            )
        )
        if !hasPaused {
            hasPaused = true
            isPaused = true
            await withCheckedContinuation { continuation = $0 }
        }
        return report
    }

    func waitUntilPaused() async {
        while !isPaused {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private extension AgentGridConfiguration {
    static let testValue = AgentGridConfiguration(
        catalog: [],
        environment: [:],
        workspace: URL(fileURLWithPath: "/work", isDirectory: true)
    )
}

private extension CLIMaintenanceReport {
    static let allReady = CLIMaintenanceReport(
        entries: AgentKind.allCases.map {
            CLIMaintenanceEntry(kind: $0, state: .ready(version: "1.0"))
        }
    )
}
