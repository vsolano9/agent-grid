import Foundation
import Observation

@MainActor
@Observable
final class CLIUsageModel {
    private(set) var snapshots = CLIUsageService.displayedKinds.map {
        ProviderUsageSnapshot(provider: $0, state: .loading, windows: [], fetchedAt: nil)
    }
    private(set) var entries = CLIUsageService.displayedKinds.map {
        CLIUsageEntry(kind: $0, state: .loading)
    }
    private(set) var isRefreshing = false

    private let reader: any CLIUsageReading
    private var hasStarted = false

    init(reader: any CLIUsageReading = CLIUsageService.live()) {
        self.reader = reader
    }

    func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            _ = try await refresh()
        } catch {
            hasStarted = false
            throw error
        }
    }

    func refresh() async throws -> ProviderRefreshOutcome {
        try await refresh(providers: Set(CLIUsageService.displayedKinds))
    }

    func refresh(providers: Set<AgentKind>) async throws -> ProviderRefreshOutcome {
        let requested = providers.intersection(Set(CLIUsageService.displayedKinds))
        guard !requested.isEmpty else {
            return ProviderRefreshOutcome(succeeded: [], failed: [])
        }
        guard !isRefreshing else {
            return ProviderRefreshOutcome(succeeded: [], failed: requested)
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let refreshed = try await reader.fetch(providers: requested)
        try Task.checkCancellation()
        let refreshedByProvider = Dictionary(uniqueKeysWithValues: refreshed.map {
            ($0.provider, $0)
        })
        let missingReason = "Account quota is not exposed by this CLI."
        snapshots = CLIUsageService.displayedKinds.map { kind in
            guard requested.contains(kind) else {
                return snapshots.first { $0.provider == kind }
                    ?? ProviderUsageSnapshot(
                        provider: kind,
                        state: .loading,
                        windows: [],
                        fetchedAt: nil
                    )
            }
            return refreshedByProvider[kind] ?? ProviderUsageSnapshot(
                provider: kind,
                state: .unavailable(reason: missingReason),
                windows: [],
                fetchedAt: nil
            )
        }
        entries = CLIUsageService.displayedKinds.map { kind in
            let snapshot = snapshots.first { $0.provider == kind }
            return CLIUsageEntry(
                kind: kind,
                state: Self.scalarState(from: snapshot)
            )
        }

        let succeeded = Set(requested.filter { kind in
            guard let snapshot = snapshots.first(where: { $0.provider == kind }) else {
                return false
            }
            if case .available = snapshot.state { return true }
            return false
        })
        return ProviderRefreshOutcome(
            succeeded: succeeded,
            failed: requested.subtracting(succeeded)
        )
    }

    private static func scalarState(from snapshot: ProviderUsageSnapshot?) -> CLIUsageState {
        guard let snapshot else {
            return .unavailable(reason: "Account quota is not exposed by this CLI.")
        }
        let mostConstrained = snapshot.windows.map(\.remainingPercent).min()
        switch snapshot.state {
        case .loading:
            return .loading
        case .available:
            guard let mostConstrained else {
                return .unavailable(reason: "Account quota is not exposed by this CLI.")
            }
            return .available(remainingPercent: mostConstrained)
        case .stale(let reason):
            guard let mostConstrained else { return .unavailable(reason: reason) }
            return .stale(remainingPercent: mostConstrained, reason: reason)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }
}
