import Foundation

struct ProviderRefreshOutcome: Equatable, Sendable {
    let succeeded: Set<AgentKind>
    let failed: Set<AgentKind>
}

enum UsageLifecycleEvent: Equatable, Sendable {
    case becameActive
    case becameInactive
    case workspaceWake
    case screenWake
    case networkSatisfied
    case networkUnsatisfied
}

struct CLIUsageRefreshCoordinatorDiagnosticState: Equatable, Sendable {
    let isActive: Bool
    let isRefreshing: Bool
    let isNetworkSatisfied: Bool
    let hasScheduledTimer: Bool
    let pendingProviders: Set<AgentKind>
    let failureCounts: [AgentKind: Int]
}

actor CLIUsageRefreshCoordinator<C: Clock> where C.Duration == Duration {
    typealias Refresh = @Sendable (Set<AgentKind>) async -> ProviderRefreshOutcome
    typealias Jitter = @Sendable (Duration) -> Duration
    typealias TimerStartup = @Sendable () async -> Void

    private enum Trigger {
        case launch
        case periodic
        case manual
        case lifecycle

        var permitsBackoffOverride: Bool {
            switch self {
            case .manual, .lifecycle: true
            case .launch, .periodic: false
            }
        }
    }

    private struct Backoff {
        var failureCount: Int
        var nextEligibleAt: C.Instant
        var overrideUsed: Bool
    }

    private struct Request {
        var providers: Set<AgentKind>
        var overriddenProviders: Set<AgentKind>
    }

    private struct PendingRequest {
        var providers: Set<AgentKind>
        var overrideEligibleProviders: Set<AgentKind>

        mutating func formUnion(_ other: Self) {
            providers.formUnion(other.providers)
            overrideEligibleProviders.formUnion(other.overrideEligibleProviders)
        }
    }

    private static var pollingInterval: Duration { .seconds(60) }
    private static var backoffIntervals: [Duration] {
        [.seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(900)]
    }

    private let clock: C
    private let jitter: Jitter
    private let providers: Set<AgentKind>
    private let timerStartup: TimerStartup
    private let refresh: Refresh

    private var isRunning = false
    private var isActive = false
    private var networkIsSatisfied = true
    private var timerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var backoffByProvider: [AgentKind: Backoff] = [:]
    private var pendingRequest: PendingRequest?

    init(
        clock: C,
        jitter: @escaping Jitter,
        providers: Set<AgentKind> = Set(CLIUsageService.displayedKinds),
        timerStartup: @escaping TimerStartup = {},
        refresh: @escaping Refresh
    ) {
        self.clock = clock
        self.jitter = jitter
        self.providers = providers
        self.timerStartup = timerStartup
        self.refresh = refresh
    }

    func run(
        isActive initialActiveState: Bool,
        lifecycleEvents: AsyncStream<UsageLifecycleEvent>
    ) async {
        guard !isRunning else { return }
        isRunning = true
        isActive = initialActiveState
        if isActive {
            scheduleTimer()
        }
        request(providers: providers, trigger: .launch)

        for await event in lifecycleEvents {
            guard !Task.isCancelled else { break }
            handle(event)
        }

        await stop()
    }

    func requestManualRefresh(providers requestedProviders: Set<AgentKind>? = nil) {
        guard isRunning, isActive else { return }
        request(providers: requestedProviders ?? providers, trigger: .manual)
    }

    func diagnosticState() -> CLIUsageRefreshCoordinatorDiagnosticState {
        CLIUsageRefreshCoordinatorDiagnosticState(
            isActive: isActive,
            isRefreshing: refreshTask != nil,
            isNetworkSatisfied: networkIsSatisfied,
            hasScheduledTimer: timerTask != nil,
            pendingProviders: pendingRequest?.providers ?? [],
            failureCounts: backoffByProvider.mapValues(\.failureCount)
        )
    }

    func stop() async {
        guard isRunning else { return }
        isActive = false
        let timerToStop = timerTask
        let refreshToStop = refreshTask
        timerToStop?.cancel()
        refreshToStop?.cancel()
        pendingRequest = nil

        await timerToStop?.value
        await refreshToStop?.value

        timerTask = nil
        refreshTask = nil
        isRunning = false
    }

    private func handle(_ event: UsageLifecycleEvent) {
        guard isRunning else { return }
        switch event {
        case .becameActive:
            guard !isActive else { return }
            isActive = true
            scheduleTimer()
            request(providers: providers, trigger: .lifecycle)
        case .becameInactive:
            guard isActive else { return }
            isActive = false
            timerTask?.cancel()
            timerTask = nil
        case .workspaceWake, .screenWake:
            guard isActive else { return }
            request(providers: providers, trigger: .lifecycle)
        case .networkUnsatisfied:
            networkIsSatisfied = false
        case .networkSatisfied:
            guard !networkIsSatisfied else { return }
            networkIsSatisfied = true
            guard isActive else { return }
            request(providers: providers, trigger: .lifecycle)
        }
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        let clock = self.clock
        let timerStartup = self.timerStartup
        let firstDeadline = clock.now.advanced(by: Self.pollingInterval)
        timerTask = Task { [weak self] in
            await timerStartup()
            var deadline = firstDeadline
            do {
                while !Task.isCancelled {
                    try await clock.sleep(until: deadline, tolerance: nil)
                    guard !Task.isCancelled else { return }
                    repeat {
                        deadline = deadline.advanced(by: Self.pollingInterval)
                    } while deadline <= clock.now
                    await self?.periodicTick()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func periodicTick() {
        guard isRunning, isActive else { return }
        request(providers: providers, trigger: .periodic)
    }

    private func request(providers requestedProviders: Set<AgentKind>, trigger: Trigger) {
        let requested = requestedProviders.intersection(providers)
        guard !requested.isEmpty else { return }

        let next = PendingRequest(
            providers: requested,
            overrideEligibleProviders: trigger.permitsBackoffOverride ? requested : []
        )
        guard refreshTask == nil else {
            if pendingRequest == nil {
                pendingRequest = next
            } else {
                pendingRequest?.formUnion(next)
            }
            return
        }
        if var pending = pendingRequest {
            pendingRequest = nil
            pending.formUnion(next)
            beginIfEligible(pending)
        } else {
            beginIfEligible(next)
        }
    }

    private func beginIfEligible(_ pending: PendingRequest) {
        var eligible: Set<AgentKind> = []
        var overridden: Set<AgentKind> = []
        for provider in pending.providers {
            guard var backoff = backoffByProvider[provider] else {
                eligible.insert(provider)
                continue
            }
            if clock.now >= backoff.nextEligibleAt {
                eligible.insert(provider)
            } else if pending.overrideEligibleProviders.contains(provider), !backoff.overrideUsed {
                backoff.overrideUsed = true
                backoffByProvider[provider] = backoff
                eligible.insert(provider)
                overridden.insert(provider)
            }
        }
        guard !eligible.isEmpty else { return }

        begin(Request(providers: eligible, overriddenProviders: overridden))
    }

    private func begin(_ request: Request) {
        let operation = refresh
        refreshTask = Task { [weak self] in
            let outcome = await operation(request.providers)
            guard !Task.isCancelled else { return }
            await self?.finish(request: request, outcome: outcome)
        }
    }

    private func finish(request: Request, outcome: ProviderRefreshOutcome) {
        refreshTask = nil
        let now = clock.now
        for provider in request.providers {
            if outcome.succeeded.contains(provider) {
                backoffByProvider[provider] = nil
                continue
            }

            let previousCount = backoffByProvider[provider]?.failureCount ?? 0
            let failureCount = previousCount + 1
            let intervalIndex = min(failureCount - 1, Self.backoffIntervals.count - 1)
            let interval = jitter(Self.backoffIntervals[intervalIndex])
            backoffByProvider[provider] = Backoff(
                failureCount: failureCount,
                nextEligibleAt: now.advanced(by: interval),
                overrideUsed: request.overriddenProviders.contains(provider)
            )
        }

        guard isActive, let pending = pendingRequest else { return }
        pendingRequest = nil
        beginIfEligible(pending)
    }
}
