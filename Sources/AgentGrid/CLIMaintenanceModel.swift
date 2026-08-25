import Foundation
import Observation

enum CLIMaintenancePhase: Equatable, Sendable {
    case idle
    case running(CLIMaintenanceProgress)
    case ready(CLIMaintenanceReport)
    case failed(CLIMaintenanceReport)
}

@MainActor
@Observable
final class CLIMaintenanceModel {
    private(set) var phase: CLIMaintenancePhase = .idle
    private(set) var configuration: AgentGridConfiguration?

    private let service: any CLIMaintaining
    private let configurationFactory: @MainActor @Sendable () -> AgentGridConfiguration

    init(
        service: any CLIMaintaining,
        configurationFactory: @escaping @MainActor @Sendable () -> AgentGridConfiguration
    ) {
        self.service = service
        self.configurationFactory = configurationFactory
    }

    convenience init() {
        self.init(
            service: CLIMaintenanceService.live(),
            configurationFactory: { AgentGridConfiguration.live() }
        )
    }

    var warningKinds: [AgentKind] {
        guard case let .ready(report) = phase else { return [] }
        return report.warnings
    }

    func start() async {
        guard phase == .idle else { return }
        await run()
    }

    func retry() async {
        guard !isRunning else { return }
        await run()
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private func run() async {
        configuration = nil
        phase = .running(
            CLIMaintenanceProgress(completedCount: 0, activeKind: nil, entries: [])
        )

        let report = await service.perform { [weak self] progress in
            await MainActor.run {
                self?.phase = .running(progress)
            }
        }

        guard !Task.isCancelled else { return }
        if report.isLaunchable {
            configuration = configurationFactory()
            phase = .ready(report)
        } else {
            phase = .failed(report)
        }
    }
}
