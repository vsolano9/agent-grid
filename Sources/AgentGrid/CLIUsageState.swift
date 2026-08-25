import Foundation

enum CLIUsageState: Equatable, Sendable {
    case loading
    case available(remainingPercent: Int)
    case unavailable(reason: String)
}

struct CLIUsageEntry: Equatable, Identifiable, Sendable {
    let kind: AgentKind
    let state: CLIUsageState

    var id: AgentKind { kind }
}
