import AppKit
import Foundation
import Testing
@testable import AgentGrid

@MainActor
@Suite("Application focus retention")
struct ApplicationFocusRetentionTests {
    @Test("AppKit mouse conversion never reads a keyboard key code")
    func appKitMouseConversionLeavesKeyCodeAbsent() throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        let converted = AppKitFocusEventSource.intentEvent(from: event)

        #expect(converted.kind == .mouseDown)
        #expect(converted.keyCode == nil)
    }

    @Test("AppKit local monitoring returns the original event unchanged")
    func appKitLocalMonitorPreservesEventIdentity() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        var received: FocusIntentEvent?

        let returned = AppKitFocusEventSource.handleLocalEvent(event) {
            received = $0
            return $0
        }

        #expect(returned === event)
        #expect(received?.kind == .keyDown)
        #expect(received?.keyCode == 48)
    }

    @Test("stopping AppKit activation observation leaves no queued callback")
    func appKitActivationStopHasNoDeferredDelivery() async {
        let center = NotificationCenter()
        let source = AppKitFocusActivationSource(notificationCenter: center)
        var observedProcessIdentifiers: [pid_t] = []
        source.start { observedProcessIdentifiers.append($0) }

        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [
                NSWorkspace.applicationUserInfoKey: NSRunningApplication.current,
            ]
        )
        #expect(observedProcessIdentifiers == [ProcessInfo.processInfo.processIdentifier])

        source.stop()
        await Task.yield()
        #expect(observedProcessIdentifiers == [ProcessInfo.processInfo.processIdentifier])
    }

    @Test("the controller arms only for an active app with a visible normal window")
    func armsOnlyWhenEligible() {
        let fixture = makeFocusFixture()

        fixture.controller.applicationDidActivate(processIdentifier: fixture.client.processIdentifier)
        #expect(fixture.controller.state == .disarmed)

        fixture.controller.updateMainWindow(isVisibleNormal: true)
        #expect(fixture.controller.state == .armed)

        fixture.controller.updateMainWindow(isVisibleNormal: false)
        #expect(fixture.controller.state == .disarmed)
    }

    @Test("a user intent creates one 1.5-second lease and disarms after the switch")
    func oneUseLease() async throws {
        let fixture = makeArmedFocusFixture()

        fixture.controller.recordUserSwitchIntent()
        #expect(fixture.controller.state == .switchLease)
        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        await settleFocusTasks()

        #expect(fixture.client.activationCount == 0)
        #expect(fixture.controller.state == .disarmed)

        fixture.controller.applicationDidActivate(processIdentifier: 43)
        fixture.clock.advance(by: .seconds(2))
        await settleFocusTasks()
        #expect(fixture.client.activationCount == 0)
    }

    @Test("an expired lease waits 120 milliseconds before reactivating and re-keying")
    func expiredLeaseRecoversAfterDecisionDelay() async throws {
        let fixture = makeArmedFocusFixture()
        fixture.controller.recordUserSwitchIntent()
        fixture.clock.advance(by: .milliseconds(1_501))

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        #expect(fixture.client.activationCount == 0)

        fixture.clock.advance(by: .milliseconds(119))
        await settleFocusTasks()
        #expect(fixture.client.activationCount == 0)

        fixture.clock.advance(by: .milliseconds(1))
        await settleFocusTasks()
        #expect(fixture.client.activationCount == 1)
        #expect(fixture.client.rekeyCount == 1)
    }

    @Test("repeat steals coalesce into one recovery sequence")
    func repeatStealsCoalesceIntoOneRecoverySequence() async throws {
        let fixture = makeArmedFocusFixture()
        fixture.client.isApplicationActive = false

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        fixture.controller.applicationDidActivate(processIdentifier: 43)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }
        try await waitForSleep(fixture.clock, count: 1)

        fixture.controller.applicationDidActivate(processIdentifier: 44)
        fixture.clock.advance(by: .milliseconds(250))
        try await eventuallyFocus { fixture.client.activationCount == 2 }
        try await waitForSleep(fixture.clock, count: 1)

        fixture.clock.advance(by: .milliseconds(250))
        try await eventuallyFocus { fixture.client.activationCount == 3 }
        try await waitForSleep(fixture.clock, count: 1)

        #expect(fixture.client.activationCount == 3)
        #expect(fixture.client.rekeyCount >= 2)
        #expect(fixture.clock.pendingSleeperCount == 1)
    }

    @Test("a slow browser launch remains recoverable beyond the first retry")
    func slowBrowserLaunchRemainsRecoverable() async throws {
        let fixture = makeArmedFocusFixture()
        fixture.client.isApplicationActive = false
        fixture.client.onActivate = {
            guard fixture.client.activationCount == 3 else { return }
            fixture.client.isApplicationActive = true
            fixture.controller.applicationDidActivate(
                processIdentifier: fixture.client.processIdentifier
            )
        }

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }

        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(250))
        try await eventuallyFocus { fixture.client.activationCount == 2 }

        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(250))
        try await eventuallyFocus { fixture.client.activationCount == 3 }

        #expect(fixture.client.isApplicationActive)
        #expect(fixture.controller.state == .armed)
    }

    @Test("an unresponsive app cannot create an unbounded focus war")
    func unresponsiveAppRecoveryIsBounded() async throws {
        let fixture = makeArmedFocusFixture()
        fixture.client.isApplicationActive = false

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }

        for expectedCount in 2...20 {
            try await waitForSleep(fixture.clock, count: 1)
            fixture.clock.advance(by: .milliseconds(250))
            try await eventuallyFocus { fixture.client.activationCount == expectedCount }
        }

        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(250))
        await settleFocusTasks()

        #expect(fixture.client.activationCount == 20)
        #expect(fixture.clock.pendingSleeperCount == 0)
        #expect(fixture.controller.state == .disarmed)

        fixture.clock.advance(by: .seconds(10))
        await settleFocusTasks()
        #expect(fixture.client.activationCount == 20)
    }

    @Test("an explicit switch lease arriving during the decision delay prevents reacquisition")
    func lateIntentWinsDecisionRace() async throws {
        let fixture = makeArmedFocusFixture()

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.controller.recordUserSwitchIntent()
        fixture.clock.advance(by: .milliseconds(120))
        await settleFocusTasks()

        #expect(fixture.client.activationCount == 0)
        #expect(fixture.controller.state == .disarmed)
    }

    @Test("an explicit switch during recovery cancels the pending retry")
    func recoveryIntentCancelsRetry() async throws {
        let fixture = makeArmedFocusFixture()
        fixture.client.isApplicationActive = false

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }
        try await waitForSleep(fixture.clock, count: 1)

        fixture.controller.recordUserSwitchIntent()
        fixture.clock.advance(by: .milliseconds(250))
        await settleFocusTasks()

        #expect(fixture.client.activationCount == 1)
        #expect(fixture.controller.state == .switchLease)
    }

    @Test("an explicit switch in the activate-to-rekey gap cancels the deferred rekey")
    func switchIntentCancelsDeferredRekey() async throws {
        let rekeyClock = FocusManualClock()
        let fixture = makeArmedFocusFixture(beforeRekey: {
            try? await rekeyClock.sleep(for: .seconds(1))
        })
        fixture.client.isApplicationActive = false

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }
        try await waitForSleep(rekeyClock, count: 1)

        fixture.controller.recordUserSwitchIntent()
        try await eventuallyFocus { rekeyClock.pendingSleeperCount == 0 }
        rekeyClock.advance(by: .seconds(1))
        await settleFocusTasks()

        #expect(fixture.client.rekeyCount == 0)
        #expect(fixture.controller.state == .switchLease)
    }

    @Test("stopping focus retention cancels a deferred rekey task")
    func stopCancelsDeferredRekey() async throws {
        let rekeyClock = FocusManualClock()
        let fixture = makeArmedFocusFixture(beforeRekey: {
            try? await rekeyClock.sleep(for: .seconds(1))
        })

        fixture.controller.applicationDidActivate(processIdentifier: 42)
        try await waitForSleep(fixture.clock, count: 1)
        fixture.clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { fixture.client.activationCount == 1 }
        try await waitForSleep(rekeyClock, count: 1)

        fixture.controller.stop()
        try await eventuallyFocus { rekeyClock.pendingSleeperCount == 0 }
        rekeyClock.advance(by: .seconds(1))
        await settleFocusTasks()

        #expect(fixture.client.rekeyCount == 0)
        #expect(fixture.controller.state == .disarmed)
    }

    @Test("focus retention can be disabled, re-enabled, and explicitly leased")
    func commandsControlRetention() {
        let fixture = makeArmedFocusFixture()

        fixture.controller.setEnabled(false)
        #expect(fixture.controller.state == .disarmed)
        fixture.controller.setEnabled(true)
        #expect(fixture.controller.state == .armed)
        fixture.controller.allowNextAppSwitch()
        #expect(fixture.controller.state == .switchLease)
    }

    @Test("monitor scope preserves local events and gates global key observation on Accessibility")
    func monitorScopeAndCleanup() {
        let fixture = makeArmedFocusFixture()
        let events = FakeFocusEventSource()
        let activations = FakeFocusActivationSource()
        var trusted = false
        var preflightCount = 0
        let monitor = FocusIntentMonitor(
            controller: fixture.controller,
            eventSource: events,
            activationSource: activations,
            accessibilityTrusted: { trusted },
            permissionPreflight: {
                preflightCount += 1
                trusted = true
            }
        )

        monitor.start()
        #expect(events.localInstallCount == 1)
        #expect(events.globalKeyModes == [false])

        let commandTab = FocusIntentEvent(
            kind: .keyDown,
            keyCode: 48,
            modifiers: [.command]
        )
        #expect(events.sendLocal(commandTab) == commandTab)
        #expect(fixture.controller.state == .switchLease)

        activations.send(fixture.client.processIdentifier)
        #expect(preflightCount == 1)
        #expect(events.globalKeyModes == [false, true])

        events.sendGlobal(FocusIntentEvent(kind: .mouseDown))
        #expect(fixture.controller.state == .switchLease)

        monitor.stop()
        #expect(events.removedTokens.count == 3)
        #expect(activations.stopCount == 1)
    }

    @Test("focus recovery activation coalesces with the usage activation refresh")
    func focusRecoveryCoalescesUsageActivationRefresh() async throws {
        let clock = FocusManualClock()
        let focus = makeArmedFocusFixture(clock: clock)
        let refreshes = FocusUsageRecorder(blockFirst: true)
        var continuation: AsyncStream<UsageLifecycleEvent>.Continuation!
        let events = AsyncStream<UsageLifecycleEvent> { continuation = $0 }
        let coordinator = CLIUsageRefreshCoordinator(
            clock: clock,
            jitter: { $0 },
            refresh: refreshes.refresh
        )
        let usageTask = Task {
            await coordinator.run(isActive: true, lifecycleEvents: events)
        }
        defer {
            usageTask.cancel()
            continuation.finish()
        }
        try await eventuallyFocusAsync { await refreshes.callCount == 1 }

        continuation.yield(.becameInactive)
        try await eventuallyFocusAsync {
            !(await coordinator.diagnosticState()).isActive
        }
        focus.client.isApplicationActive = false
        focus.client.onActivate = {
            focus.client.isApplicationActive = true
            continuation.yield(.becameActive)
        }

        focus.controller.applicationDidActivate(processIdentifier: 42)
        try await eventuallyFocus { clock.pendingSleeperCount == 1 }
        clock.advance(by: .milliseconds(120))
        try await eventuallyFocusAsync {
            let state = await coordinator.diagnosticState()
            return focus.client.activationCount == 1
                && state.isActive
                && state.pendingProviders == Set(CLIUsageService.displayedKinds)
        }

        await refreshes.releaseFirst()
        try await eventuallyFocusAsync { await refreshes.callCount == 2 }
        try await eventuallyFocusAsync {
            let state = await coordinator.diagnosticState()
            return !state.isRefreshing && state.pendingProviders.isEmpty
        }
        await settleFocusTasks()
        #expect(await refreshes.callCount == 2)
    }

    @Test("an explicit user switch keeps usage polling inactive until AgentGrid returns")
    func userSwitchSuspendsUsageTimerUntilReturn() async throws {
        let clock = FocusManualClock()
        let focus = makeArmedFocusFixture(clock: clock)
        let refreshes = FocusUsageRecorder()
        var continuation: AsyncStream<UsageLifecycleEvent>.Continuation!
        let events = AsyncStream<UsageLifecycleEvent> { continuation = $0 }
        let coordinator = CLIUsageRefreshCoordinator(
            clock: clock,
            jitter: { $0 },
            refresh: refreshes.refresh
        )
        let usageTask = Task {
            await coordinator.run(isActive: true, lifecycleEvents: events)
        }
        defer {
            usageTask.cancel()
            continuation.finish()
        }
        try await eventuallyFocusAsync {
            let state = await coordinator.diagnosticState()
            return await refreshes.callCount == 1
                && !state.isRefreshing
                && state.hasScheduledTimer
        }

        focus.controller.recordUserSwitchIntent()
        focus.controller.applicationDidActivate(processIdentifier: 42)
        continuation.yield(.becameInactive)
        try await eventuallyFocusAsync {
            let state = await coordinator.diagnosticState()
            return !state.isActive && !state.hasScheduledTimer
        }
        clock.advance(by: .milliseconds(120))
        try await eventuallyFocus { focus.controller.state == .disarmed }

        clock.advance(by: .seconds(180))
        await settleFocusTasks()
        #expect(await refreshes.callCount == 1)

        focus.client.isApplicationActive = true
        focus.controller.applicationDidActivate(
            processIdentifier: focus.client.processIdentifier
        )
        continuation.yield(.becameActive)
        try await eventuallyFocusAsync {
            let state = await coordinator.diagnosticState()
            return await refreshes.callCount == 2
                && state.isActive
                && !state.isRefreshing
                && state.hasScheduledTimer
        }
        #expect(focus.controller.state == .armed)
    }

    @Test("Command-Tab is classified by either event-monitor scope")
    func classifiesCommandTabInEitherScope() {
        let event = FocusIntentEvent(
            kind: .keyDown,
            keyCode: 48,
            modifiers: [.command, .shift]
        )

        #expect(FocusIntentClassifier.isExplicitSwitch(event, scope: .local))
        #expect(FocusIntentClassifier.isExplicitSwitch(event, scope: .global))
        #expect(!FocusIntentClassifier.isExplicitSwitch(
            FocusIntentEvent(kind: .keyDown, keyCode: 48),
            scope: .local
        ))
    }
}

@MainActor
private struct FocusFixture {
    let clock: FocusManualClock
    let client: FakeFocusActivationClient
    let controller: ApplicationFocusRetentionController<FocusManualClock>
}

@MainActor
private func makeFocusFixture(
    clock: FocusManualClock = FocusManualClock(),
    beforeRekey: @escaping @MainActor @Sendable () async -> Void = { await Task.yield() }
) -> FocusFixture {
    let client = FakeFocusActivationClient()
    let controller = ApplicationFocusRetentionController(
        clock: clock,
        activationClient: client,
        beforeRekey: beforeRekey
    )
    return FocusFixture(clock: clock, client: client, controller: controller)
}

@MainActor
private func makeArmedFocusFixture(
    clock: FocusManualClock = FocusManualClock(),
    beforeRekey: @escaping @MainActor @Sendable () async -> Void = { await Task.yield() }
) -> FocusFixture {
    let fixture = makeFocusFixture(clock: clock, beforeRekey: beforeRekey)
    fixture.client.isApplicationActive = true
    fixture.client.isMainWindowVisibleNormal = true
    fixture.controller.updateMainWindow(isVisibleNormal: true)
    fixture.controller.applicationDidActivate(processIdentifier: fixture.client.processIdentifier)
    return fixture
}

@MainActor
private final class FakeFocusActivationClient: FocusActivationClient {
    let processIdentifier: pid_t = 7
    var isApplicationActive = false
    var isMainWindowVisibleNormal = false
    private(set) var activationCount = 0
    private(set) var rekeyCount = 0
    var onActivate: (() -> Void)?

    func activate() {
        activationCount += 1
        onActivate?()
    }
    func rekeyMainWindow() { rekeyCount += 1 }
}

@MainActor
private final class FakeFocusEventSource: FocusEventSource {
    private(set) var localInstallCount = 0
    private(set) var globalKeyModes: [Bool] = []
    private(set) var removedTokens: [Int] = []
    private var nextToken = 0
    private var localHandler: ((FocusIntentEvent) -> FocusIntentEvent)?
    private var globalHandler: ((FocusIntentEvent) -> Void)?

    func installLocal(
        handler: @escaping (FocusIntentEvent) -> FocusIntentEvent
    ) -> Int {
        localInstallCount += 1
        localHandler = handler
        return token()
    }

    func installGlobal(
        includeKeyEvents: Bool,
        handler: @escaping (FocusIntentEvent) -> Void
    ) -> Int {
        globalKeyModes.append(includeKeyEvents)
        globalHandler = handler
        return token()
    }

    func remove(_ token: Int) { removedTokens.append(token) }
    func sendLocal(_ event: FocusIntentEvent) -> FocusIntentEvent { localHandler?(event) ?? event }
    func sendGlobal(_ event: FocusIntentEvent) { globalHandler?(event) }

    private func token() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }
}

@MainActor
private final class FakeFocusActivationSource: FocusActivationSource {
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (pid_t) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (pid_t) -> Void) { self.handler = handler }
    func stop() { stopCount += 1; handler = nil }
    func send(_ pid: pid_t) { handler?(pid) }
}

private struct FocusManualClock: Clock, @unchecked Sendable {
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
                    storage.waiters[id] = Storage.Waiter(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
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
            let keys = storage.waiters.filter { $0.value.deadline <= storage.now }.map(\.key)
            keys.forEach { storage.waiters[$0] = nil }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private func waitForSleep(_ clock: FocusManualClock, count: Int) async throws {
    try await eventuallyFocus { clock.pendingSleeperCount == count }
}

private func eventuallyFocus(_ predicate: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
        if await MainActor.run(body: predicate) { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}

private func eventuallyFocusAsync(
    _ predicate: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
    throw FocusIntegrationWaitError.conditionTimedOut
}

private enum FocusIntegrationWaitError: Error {
    case conditionTimedOut
}

private actor FocusUsageRecorder {
    private(set) var callCount = 0
    private var shouldBlockFirst: Bool
    private var firstContinuation: CheckedContinuation<Void, Error>?

    init(blockFirst: Bool = false) {
        shouldBlockFirst = blockFirst
    }

    func refresh(_ providers: Set<AgentKind>) async -> ProviderRefreshOutcome {
        callCount += 1
        if shouldBlockFirst {
            shouldBlockFirst = false
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        firstContinuation = continuation
                    }
                } onCancel: {
                    Task { await self.cancelFirst() }
                }
            } catch {
                return ProviderRefreshOutcome(succeeded: [], failed: providers)
            }
        }
        return ProviderRefreshOutcome(succeeded: providers, failed: [])
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func cancelFirst() {
        firstContinuation?.resume(throwing: CancellationError())
        firstContinuation = nil
    }
}

private func settleFocusTasks() async {
    for _ in 0..<100 { await Task.yield() }
}
