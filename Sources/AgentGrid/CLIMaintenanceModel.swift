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

    private let serviceFactory: @Sendable () async -> (any CLIMaintaining)?
    private let configurationFactory: @MainActor @Sendable () -> AgentGridConfiguration

    init(
        service: any CLIMaintaining,
        configurationFactory: @escaping @MainActor @Sendable () -> AgentGridConfiguration
    ) {
        serviceFactory = { service }
        self.configurationFactory = configurationFactory
    }

    private init(
        serviceFactory: @escaping @Sendable () async -> (any CLIMaintaining)?,
        configurationFactory: @escaping @MainActor @Sendable () -> AgentGridConfiguration
    ) {
        self.serviceFactory = serviceFactory
        self.configurationFactory = configurationFactory
    }

    convenience init(
        liveBaseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        liveHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        directoryContents: @escaping @Sendable (URL) -> [URL] = {
            (try? FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
    ) {
        let loader = LiveCLIMaintenanceServiceLoader(
            baseEnvironment: liveBaseEnvironment,
            homeDirectory: liveHomeDirectory,
            directoryContents: directoryContents
        )
        self.init(
            serviceFactory: { await loader.load() },
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
            CLIMaintenanceProgress(
                completedCount: 0,
                activeKind: nil,
                stage: nil,
                entries: []
            )
        )

        guard let service = await serviceFactory(), !Task.isCancelled else {
            phase = .idle
            return
        }
        let report = await service.perform { [weak self] progress in
            await MainActor.run {
                self?.phase = .running(progress)
            }
        }

        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        if report.isLaunchable {
            configuration = configurationFactory()
            phase = .ready(report)
        } else {
            phase = .failed(report)
        }
    }
}

private actor LiveCLIMaintenanceServiceLoader {
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL
    private let directoryContents: @Sendable (URL) -> [URL]

    init(
        baseEnvironment: [String: String],
        homeDirectory: URL,
        directoryContents: @escaping @Sendable (URL) -> [URL]
    ) {
        self.baseEnvironment = baseEnvironment
        self.homeDirectory = homeDirectory
        self.directoryContents = directoryContents
    }

    func load() -> (any CLIMaintaining)? {
        guard !Task.isCancelled else { return nil }
        let service = CLIMaintenanceService.live(
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            directoryContents: directoryContents
        )
        return Task.isCancelled ? nil : service
    }
}
