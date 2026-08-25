import Foundation
import Observation

@MainActor
@Observable
final class CLIUsageModel {
    private(set) var entries = AgentKind.allCases.map {
        CLIUsageEntry(kind: $0, state: .loading)
    }
    private(set) var isRefreshing = false

    private let reader: any CLIUsageReading
    private var hasStarted = false

    init(reader: any CLIUsageReading = CLIUsageService.live()) {
        self.reader = reader
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let values = await reader.fetch()
        entries = AgentKind.allCases.map { kind in
            CLIUsageEntry(
                kind: kind,
                state: values[kind]
                    ?? .unavailable(reason: "Account quota is not exposed by this CLI.")
            )
        }
    }
}
