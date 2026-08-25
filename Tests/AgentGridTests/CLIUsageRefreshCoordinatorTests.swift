import Foundation
import Testing
@testable import AgentGrid

@Suite("CLI usage refresh orchestration")
struct CLIUsageRefreshCoordinatorTests {
    @Test("launch refreshes immediately and foreground polling waits for each 60-second boundary")
    func launchAndCadence() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder()
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        #expect(await recorder.calls == [Set(CLIUsageService.displayedKinds)])

        clock.advance(by: .seconds(59))
        await settle()
        #expect(await recorder.calls.count == 1)

        clock.advance(by: .seconds(1))
        try await eventually { await recorder.calls.count == 2 }
        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 3 }
    }

    @Test("the first polling deadline is fixed before the timer task starts")
    func firstDeadlineSurvivesImmediateAdvance() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder()
        let timerStartup = TimerStartupGate()
        let fixture = makeFixture(
            clock: clock,
            recorder: recorder,
            timerStartup: timerStartup.wait
        )
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        try await eventually { await timerStartup.hasWaiter }

        clock.advance(by: .seconds(60))
        await timerStartup.open()

        try await eventually { await recorder.calls.count == 2 }
    }

    @Test("a large foreground clock advance produces one periodic pass without a catch-up storm")
    func largeAdvanceCoalescesMissedBoundaries() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder()
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        try await eventually { clock.pendingSleeperCount == 1 }

        clock.advance(by: .seconds(300))

        try await eventually { await recorder.calls.count == 2 }
        await settle()
        #expect(await recorder.calls.count == 2)
        #expect(clock.pendingSleeperCount == 1)
    }

    @Test("launch performs one immediate pass even when the app starts inactive")
    func inactiveLaunchStillRefreshesOnce() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder()
        let fixture = makeFixture(clock: clock, recorder: recorder, isActive: false)
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        clock.advance(by: .seconds(180))
        await settle()
        #expect(await recorder.calls.count == 1)
    }

    @Test("inactive suspension and activation, wake, screen wake, and network recovery are immediate")
    func lifecycleRecovery() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder()
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        fixture.events.yield(.becameInactive)
        try await eventually {
            !(await fixture.coordinator.diagnosticState()).isActive
        }
        clock.advance(by: .seconds(180))
        await settle()
        #expect(await recorder.calls.count == 1)

        fixture.events.yield(.becameActive)
        try await eventually { await recorder.calls.count == 2 }
        fixture.events.yield(.workspaceWake)
        try await eventually { await recorder.calls.count == 3 }
        fixture.events.yield(.screenWake)
        try await eventually { await recorder.calls.count == 4 }

        fixture.events.yield(.networkSatisfied)
        await settle()
        fixture.events.yield(.networkSatisfied)
        await settle()
        #expect(await recorder.calls.count == 4)

        fixture.events.yield(.networkUnsatisfied)
        fixture.events.yield(.networkSatisfied)
        try await eventually { await recorder.calls.count == 5 }
    }

    @MainActor
    @Test("network recovery overrides provider backoff and preserves mixed fresh and stale windows")
    func networkRecoveryPreservesMixedWindowFreshness() async throws {
        let clock = ManualClock()
        let codex = IntegrationProviderReader(results: [
            .success(integrationObservation(
                provider: .codex,
                key: "primary",
                remainingPercent: 64,
                fetchedAt: 100
            )),
            .failure(IntegrationUsageError.offline),
            .failure(IntegrationUsageError.offline),
        ])
        let claude = IntegrationProviderReader(results: [
            .success(integrationObservation(
                provider: .claude,
                key: "five_hour",
                remainingPercent: 82,
                fetchedAt: 100
            )),
            .success(integrationObservation(
                provider: .claude,
                key: "five_hour",
                remainingPercent: 77,
                fetchedAt: 200
            )),
            .success(integrationObservation(
                provider: .claude,
                key: "five_hour",
                remainingPercent: 71,
                fetchedAt: 300
            )),
        ])
        let model = CLIUsageModel(reader: CLIUsageService(readers: [
            .codex: codex,
            .claude: claude,
        ]))
        var continuation: AsyncStream<UsageLifecycleEvent>.Continuation!
        let events = AsyncStream<UsageLifecycleEvent> { continuation = $0 }
        let coordinator = CLIUsageRefreshCoordinator(
            clock: clock,
            jitter: { $0 },
            providers: [.codex, .claude],
            refresh: { providers in
                do {
                    return try await model.refresh(providers: providers)
                } catch {
                    return ProviderRefreshOutcome(succeeded: [], failed: providers)
                }
            }
        )
        let task = Task { await coordinator.run(isActive: true, lifecycleEvents: events) }
        defer {
            task.cancel()
            continuation.finish()
        }

        try await eventually {
            let state = await coordinator.diagnosticState()
            let codexCalls = await codex.callCount
            let claudeCalls = await claude.callCount
            return !state.isRefreshing
                && state.hasScheduledTimer
                && codexCalls == 1
                && claudeCalls == 1
        }

        clock.advance(by: .seconds(60))
        try await eventually {
            let state = await coordinator.diagnosticState()
            let codexCalls = await codex.callCount
            let claudeCalls = await claude.callCount
            return !state.isRefreshing
                && state.failureCounts[.codex] == 1
                && codexCalls == 2
                && claudeCalls == 2
        }

        continuation.yield(.networkUnsatisfied)
        try await eventually {
            !(await coordinator.diagnosticState()).isNetworkSatisfied
        }
        continuation.yield(.networkSatisfied)
        try await eventually {
            let state = await coordinator.diagnosticState()
            let codexCalls = await codex.callCount
            let claudeCalls = await claude.callCount
            return !state.isRefreshing
                && state.failureCounts[.codex] == 2
                && codexCalls == 3
                && claudeCalls == 3
        }

        let codexSnapshot = try #require(model.snapshots.first { $0.provider == .codex })
        let claudeSnapshot = try #require(model.snapshots.first { $0.provider == .claude })
        #expect(codexSnapshot.state == .stale(reason: "Codex quota could not be refreshed."))
        #expect(codexSnapshot.windows.first?.freshness == .stale(
            reason: "Codex quota could not be refreshed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(claudeSnapshot.state == .available)
        #expect(claudeSnapshot.windows.first?.freshness == .fresh)
        #expect(claudeSnapshot.windows.first?.remainingPercent == 71)
    }

    @Test("in-flight triggers union provider sets into exactly one follow-up")
    func coalescesOneFollowUp() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(blockFirst: true)
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        await fixture.coordinator.requestManualRefresh(providers: [.codex])
        await fixture.coordinator.requestManualRefresh(providers: [.claude])
        fixture.events.yield(.workspaceWake)
        await settle()
        await recorder.releaseFirst()

        try await eventually { await recorder.calls.count == 2 }
        #expect(await recorder.calls[1] == Set(CLIUsageService.displayedKinds))
        await settle()
        #expect(await recorder.calls.count == 2)
    }

    @Test("an in-flight refresh may complete while inactive without restarting the timer")
    func refreshCompletionWhileInactiveKeepsTimerSuspended() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(blockFirst: true)
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        fixture.events.yield(.becameInactive)
        try await eventually {
            let state = await fixture.coordinator.diagnosticState()
            return !state.isActive && !state.hasScheduledTimer
        }
        await recorder.releaseFirst()
        try await eventually {
            !(await fixture.coordinator.diagnosticState()).isRefreshing
        }

        clock.advance(by: .seconds(180))
        await settle()
        let state = await fixture.coordinator.diagnosticState()
        #expect(!state.isActive)
        #expect(!state.hasScheduledTimer)
        #expect(await recorder.calls.count == 1)
    }

    @Test("wake and network recovery during one in-flight read produce one follow-up pass")
    func wakeAndNetworkRecoveryCoalesceOneFollowUp() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(blockFirst: true)
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        fixture.events.yield(.workspaceWake)
        fixture.events.yield(.networkUnsatisfied)
        try await eventually {
            !(await fixture.coordinator.diagnosticState()).isNetworkSatisfied
        }
        fixture.events.yield(.networkSatisfied)
        try await eventually {
            await fixture.coordinator.diagnosticState().pendingProviders
                == Set(CLIUsageService.displayedKinds)
        }

        await recorder.releaseFirst()
        try await eventually { await recorder.calls.count == 2 }
        try await eventually {
            let state = await fixture.coordinator.diagnosticState()
            return !state.isRefreshing && state.pendingProviders.isEmpty
        }
        await settle()
        #expect(await recorder.calls.count == 2)
    }

    @Test("a pending pass held while inactive coalesces with activation")
    func inactivePendingCoalescesWithActivation() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(blockFirst: true)
        let fixture = makeFixture(clock: clock, recorder: recorder)
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        fixture.events.yield(.workspaceWake)
        fixture.events.yield(.becameInactive)
        await settle()
        await recorder.releaseFirst()
        await settle()
        #expect(await recorder.calls.count == 1)

        fixture.events.yield(.becameActive)
        try await eventually { await recorder.calls.count == 2 }
        await settle()
        #expect(await recorder.calls.count == 2)
    }

    @Test("a queued periodic pass is re-evaluated after an in-flight failure")
    func queuedPeriodicHonorsNewBackoff() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(failing: [.codex], blockFirst: true)
        let fixture = makeFixture(
            clock: clock,
            recorder: recorder,
            providers: [.codex]
        )
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(60))
        await settle()
        await recorder.releaseFirst()
        await settle()

        #expect(await recorder.calls.count == 1)

        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 2 }
    }

    @Test("a queued manual pass consumes the one backoff override")
    func queuedManualConsumesOverride() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(failing: [.codex], blockFirst: true)
        let fixture = makeFixture(
            clock: clock,
            recorder: recorder,
            providers: [.codex]
        )
        defer { fixture.stop() }

        try await eventually { await recorder.calls.count == 1 }
        await fixture.coordinator.requestManualRefresh()
        await recorder.releaseFirst()
        try await eventually { await recorder.calls.count == 2 }
        await settle()

        await fixture.coordinator.requestManualRefresh()
        await settle()

        #expect(await recorder.calls.count == 2)
    }

    @Test("provider failures back off independently at 60, 120, 240, 480, and 900 seconds")
    func independentBackoff() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(failing: [.codex])
        let fixture = makeFixture(clock: clock, recorder: recorder, providers: [.codex, .claude])
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }
        await settle()

        for expectedCount in 2...5 {
            clock.advance(by: .seconds(60))
            try await eventually { await recorder.calls.count == expectedCount }
            await settle()
        }
        let firstFive = await recorder.calls
        #expect(firstFive[1] == [.codex, .claude])
        #expect(firstFive[2] == [.claude])
        #expect(firstFive[3] == [.codex, .claude])
        #expect(firstFive[4] == [.claude])

        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 6 }
        await settle()
        #expect(await recorder.calls[5] == [.claude])

        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 7 }
        await settle()
        #expect(await recorder.calls[6] == [.claude])

        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 8 }
        await settle()
        #expect(await recorder.calls[7] == [.codex, .claude])
    }

    @Test("failure eligibility follows the complete capped backoff schedule")
    func completeBackoffSchedule() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(failing: [.codex])
        let fixture = makeFixture(clock: clock, recorder: recorder, providers: [.codex])
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }
        await settle()

        let expectedAttemptByMinute = [1: 2, 3: 3, 7: 4, 15: 5, 30: 6]
        for minute in 1...30 {
            clock.advance(by: .seconds(60))
            if let expectedCount = expectedAttemptByMinute[minute] {
                try await eventually { await recorder.calls.count == expectedCount }
                await settle()
            } else {
                await settle()
                let expectedCount = expectedAttemptByMinute
                    .filter { $0.key < minute }
                    .values
                    .max() ?? 1
                #expect(await recorder.calls.count == expectedCount)
            }
        }
    }

    @Test("a success resets only that provider's backoff")
    func successResetsProviderBackoff() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(outcomes: [
            [.codex: false, .claude: false],
            [.codex: true, .claude: false],
            [.codex: true, .claude: true],
        ])
        let fixture = makeFixture(clock: clock, recorder: recorder, providers: [.codex, .claude])
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }
        try await eventually {
            let state = await fixture.coordinator.diagnosticState()
            return !state.isRefreshing
                && state.failureCounts[.codex] == 1
                && state.failureCounts[.claude] == 1
        }

        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 2 }
        try await eventually {
            let state = await fixture.coordinator.diagnosticState()
            return !state.isRefreshing
                && state.failureCounts[.codex] == nil
                && state.failureCounts[.claude] == 2
        }
        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 3 }

        #expect(await recorder.calls[2] == [.codex])
    }

    @Test("manual and lifecycle triggers get one override while a provider is backing off")
    func oneOverrideDuringBackoff() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(failing: [.grok])
        let fixture = makeFixture(clock: clock, recorder: recorder, providers: [.grok])
        defer { fixture.stop() }
        try await eventually { await recorder.calls.count == 1 }

        await fixture.coordinator.requestManualRefresh()
        try await eventually { await recorder.calls.count == 2 }
        fixture.events.yield(.workspaceWake)
        await settle()
        await fixture.coordinator.requestManualRefresh()
        await settle()
        #expect(await recorder.calls.count == 2)

        clock.advance(by: .seconds(60))
        await settle()
        #expect(await recorder.calls.count == 2)
        clock.advance(by: .seconds(60))
        try await eventually { await recorder.calls.count == 3 }
        fixture.events.yield(.screenWake)
        try await eventually { await recorder.calls.count == 4 }
    }

    @Test("cancellation tears down the clock, lifecycle stream, and active read")
    func cancellationCleanup() async throws {
        let clock = ManualClock()
        let recorder = RefreshRecorder(blockFirst: true)
        let termination = TerminationProbe()
        let fixture = makeFixture(clock: clock, recorder: recorder, termination: termination)
        try await eventually { await recorder.calls.count == 1 }

        fixture.task.cancel()

        try await eventually { await recorder.cancellationCount == 1 }
        try await eventually { termination.wasTerminated }
        #expect(clock.pendingSleeperCount == 0)
        fixture.events.finish()
    }
}

private struct CoordinatorFixture {
    let coordinator: CLIUsageRefreshCoordinator<ManualClock>
    let events: AsyncStream<UsageLifecycleEvent>.Continuation
    let task: Task<Void, Never>

    func stop() {
        task.cancel()
        events.finish()
    }
}

private func makeFixture(
    clock: ManualClock,
    recorder: RefreshRecorder,
    providers: Set<AgentKind> = Set(CLIUsageService.displayedKinds),
    isActive: Bool = true,
    termination: TerminationProbe? = nil,
    timerStartup: @escaping @Sendable () async -> Void = {}
) -> CoordinatorFixture {
    var continuation: AsyncStream<UsageLifecycleEvent>.Continuation!
    let stream = AsyncStream<UsageLifecycleEvent> { value in
        continuation = value
        value.onTermination = { _ in termination?.markTerminated() }
    }
    let coordinator = CLIUsageRefreshCoordinator(
        clock: clock,
        jitter: { $0 },
        providers: providers,
        timerStartup: timerStartup,
        refresh: recorder.refresh
    )
    let task = Task {
        await coordinator.run(isActive: isActive, lifecycleEvents: stream)
    }
    return CoordinatorFixture(coordinator: coordinator, events: continuation, task: task)
}

private actor TimerStartupGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RefreshRecorder {
    private(set) var calls: [Set<AgentKind>] = []
    private(set) var cancellationCount = 0
    private let failing: Set<AgentKind>
    private var outcomes: [[AgentKind: Bool]]
    private var firstContinuation: CheckedContinuation<Void, Error>?
    private var shouldBlockFirst: Bool

    init(
        failing: Set<AgentKind> = [],
        outcomes: [[AgentKind: Bool]] = [],
        blockFirst: Bool = false
    ) {
        self.failing = failing
        self.outcomes = outcomes
        shouldBlockFirst = blockFirst
    }

    func refresh(_ providers: Set<AgentKind>) async -> ProviderRefreshOutcome {
        calls.append(providers)
        if shouldBlockFirst {
            shouldBlockFirst = false
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        firstContinuation = continuation
                    }
                } onCancel: {
                    Task { await self.cancelBlockedRead() }
                }
            } catch is CancellationError {
                cancellationCount += 1
                return ProviderRefreshOutcome(succeeded: [], failed: providers)
            } catch {
                return ProviderRefreshOutcome(succeeded: [], failed: providers)
            }
        }

        let configured = outcomes.isEmpty ? nil : outcomes.removeFirst()
        let succeeded = Set(providers.filter { configured?[$0] ?? !failing.contains($0) })
        return ProviderRefreshOutcome(succeeded: succeeded, failed: providers.subtracting(succeeded))
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func cancelBlockedRead() {
        firstContinuation?.resume(throwing: CancellationError())
        firstContinuation = nil
    }
}

private final class TerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var wasTerminated: Bool { lock.withLock { terminated } }
    func markTerminated() { lock.withLock { terminated = true } }
}

private struct ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    private final class Storage: @unchecked Sendable {
        struct Waiter {
            let deadline: Instant
            let continuation: CheckedContinuation<Void, Error>
        }

        let lock = NSLock()
        var now = Instant(offset: .zero)
        var waiters: [UUID: Waiter] = [:]
        var cancelled: Set<UUID> = []
    }

    private let storage = Storage()
    var now: Instant { storage.lock.withLock { storage.now } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var pendingSleeperCount: Int { storage.lock.withLock { storage.waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Void, Error>? = storage.lock.withLock {
                    if storage.cancelled.remove(id) != nil || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if deadline <= storage.now { return .success(()) }
                    storage.waiters[id] = Storage.Waiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return nil
                }
                if let result {
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let waiter = storage.lock.withLock { () -> Storage.Waiter? in
                if let waiter = storage.waiters.removeValue(forKey: id) { return waiter }
                storage.cancelled.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = storage.lock.withLock { () -> [Storage.Waiter] in
            storage.now = storage.now.advanced(by: duration)
            let ready = storage.waiters.values.filter { $0.deadline <= storage.now }
            let readyIDs = storage.waiters.filter { $0.value.deadline <= storage.now }.map(\.key)
            readyIDs.forEach { storage.waiters[$0] = nil }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
    throw CoordinatorTestWaitError.conditionTimedOut
}

private enum CoordinatorTestWaitError: Error {
    case conditionTimedOut
}

private enum IntegrationUsageError: Error {
    case offline
}

private actor IntegrationProviderReader: ProviderQuotaReading {
    private var results: [Result<ProviderUsageObservation, Error>]
    private(set) var callCount = 0

    init(results: [Result<ProviderUsageObservation, Error>]) {
        self.results = results
    }

    func fetchObservation() async throws -> ProviderUsageObservation {
        callCount += 1
        guard !results.isEmpty else { throw IntegrationUsageError.offline }
        return try results.removeFirst().get()
    }
}

private func integrationObservation(
    provider: AgentKind,
    key: String,
    remainingPercent: Int,
    fetchedAt: TimeInterval
) -> ProviderUsageObservation {
    ProviderUsageObservation(
        windows: [.available(ProviderUsageWindowValue(
            id: ProviderUsageWindowID(provider: provider, key: key),
            label: key,
            remainingPercent: remainingPercent,
            resetsAt: nil
        ))],
        fetchedAt: Date(timeIntervalSince1970: fetchedAt)
    )
}

private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}
