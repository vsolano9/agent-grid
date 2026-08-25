import Foundation

struct ProviderUsageWindowID: Hashable, Sendable {
    let provider: AgentKind
    let key: String
}

struct ProviderUsageWindowValue: Equatable, Sendable {
    let id: ProviderUsageWindowID
    let label: String
    let remainingPercent: Int
    let resetsAt: Date?
}

enum ProviderUsageWindowObservation: Equatable, Sendable {
    case available(ProviderUsageWindowValue)
    case failed(id: ProviderUsageWindowID, reason: String)
    case removed(ProviderUsageWindowID)

    var id: ProviderUsageWindowID {
        switch self {
        case .available(let value): value.id
        case .failed(let id, _), .removed(let id): id
        }
    }
}

struct ProviderUsageObservation: Equatable, Sendable {
    let windows: [ProviderUsageWindowObservation]
    let fetchedAt: Date
}

enum ProviderUsageFreshness: Equatable, Sendable {
    case fresh
    case stale(reason: String, lastSuccessfulAt: Date)
}

struct ProviderUsageWindow: Equatable, Identifiable, Sendable {
    let value: ProviderUsageWindowValue
    let freshness: ProviderUsageFreshness
    let lastSuccessfulAt: Date

    var id: ProviderUsageWindowID { value.id }
    var label: String { value.label }
    var remainingPercent: Int { value.remainingPercent }
    var resetsAt: Date? { value.resetsAt }
}

enum ProviderUsageSnapshotState: Equatable, Sendable {
    case loading
    case available
    case stale(reason: String)
    case unavailable(reason: String)
}

struct ProviderUsageSnapshot: Equatable, Identifiable, Sendable {
    let provider: AgentKind
    let state: ProviderUsageSnapshotState
    let windows: [ProviderUsageWindow]
    let fetchedAt: Date?

    var id: AgentKind { provider }
}
