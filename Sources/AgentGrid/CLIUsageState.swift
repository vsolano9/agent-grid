import Foundation

enum CLIUsageState: Equatable, Sendable {
    case loading
    case available(remainingPercent: Int)
    case stale(remainingPercent: Int, reason: String)
    case unavailable(reason: String)
}

struct CLIUsageEntry: Equatable, Identifiable, Sendable {
    let kind: AgentKind
    let state: CLIUsageState

    var id: AgentKind { kind }
}
