import CoreGraphics
import Foundation
import Testing
@testable import AgentGrid

struct RuntimePolicyTests {
    @Test("app bundle reports release 1.3.4 build 9")
    func releaseMetadata() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.3.4")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "9")
    }

    @Test("The Work root is preferred when it exists")
    func preferredWorkspace() {
        let work = URL(fileURLWithPath: "/Volumes/Extreme Pro/Documents/Work")
        let home = URL(fileURLWithPath: "/home/test")
        let locator = WorkspaceLocator(
            preferredWorkspace: work,
            homeDirectory: home,
            isDirectory: { $0 == work }
        )

        #expect(locator.workspace() == work)
    }

    @Test("Home is used when the Work root is unavailable")
    func homeFallback() {
        let home = URL(fileURLWithPath: "/home/test")
        let locator = WorkspaceLocator(
            preferredWorkspace: URL(fileURLWithPath: "/missing"),
            homeDirectory: home,
            isDirectory: { _ in false }
        )

        #expect(locator.workspace() == home)
    }

    @Test("Terminal environment puts canonical CLI aliases ahead of inherited paths")
    func terminalEnvironment() throws {
        let environment = TerminalEnvironment.make(
            base: ["PATH": "/custom/bin", "LANG": "en_US.UTF-8"],
            homeDirectory: URL(fileURLWithPath: "/home/test")
        )
        let path = try #require(environment["PATH"])

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(path.split(separator: ":").map(String.init) == [
            "/home/test/.local/bin",
            "/custom/bin",
            "/home/test/.grok/bin",
            "/home/test/.cursor/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])
    }

    @Test("Maximized windows use the screen's visible frame")
    func maximizedFrame() {
        let visibleFrame = CGRect(x: 0, y: 48, width: 1728, height: 1069)

        #expect(WindowFramePolicy.maximizedFrame(for: visibleFrame) == visibleFrame)
    }

    @Test("hosted unit tests never start live application operations")
    func hostedUnitTestsSkipLiveOperations() {
        let loadedTestBundle = URL(fileURLWithPath: "/tmp/AgentGridTests.xctest")
        let loadedAppBundle = URL(fileURLWithPath: "/tmp/AgentGrid.app")
        let exists: @Sendable (URL) -> Bool = { $0 == loadedTestBundle }
        let alwaysExists: @Sendable (URL) -> Bool = { _ in true }
        let neverExists: @Sendable (URL) -> Bool = { _ in false }

        #expect(AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [:],
            loadedBundleURLs: [loadedTestBundle],
            fileExists: exists
        ))
        #expect(AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [
                "XCTestBundlePath": "AgentGridTests.xctest",
                "XCTestSessionIdentifier": "session",
            ],
            loadedBundleURLs: [],
            fileExists: exists
        ))
        #expect(AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [
                "XCTestBundlePath": loadedAppBundle.path,
                "XCTestSessionIdentifier": "session",
            ],
            loadedBundleURLs: [loadedAppBundle],
            fileExists: alwaysExists
        ))
        #expect(AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [
                "XCTestBundlePath": loadedTestBundle.path,
                "XCTestSessionIdentifier": "session",
            ],
            loadedBundleURLs: [loadedTestBundle],
            fileExists: neverExists
        ))
        #expect(AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [
                "XCTestBundlePath": loadedTestBundle.path,
                "XCTestSessionIdentifier": "session",
            ],
            loadedBundleURLs: [],
            fileExists: exists
        ))
        #expect(!AgentGridRuntimePolicy.shouldRunLiveOperations(
            environment: [
                "XCTestBundlePath": loadedTestBundle.path,
                "XCTestSessionIdentifier": "session",
            ],
            loadedBundleURLs: [loadedTestBundle],
            fileExists: exists
        ))
        #expect(!AgentGridRuntimePolicy.shouldRunLiveOperations())
    }

    @MainActor
    @Test("maintenance finishes before usage starts while focus starts in parallel")
    func maintenanceSequencesUsage() async {
        let maintenanceGate = RuntimeAsyncGate()
        let usageStarted = RuntimeFlag()
        let focusStarted = RuntimeFlag()
        let runtime = AgentGridApplicationRuntime(
            maintenance: {
                await maintenanceGate.hold()
                return true
            },
            usage: {
                usageStarted.mark()
            },
            focus: {
                focusStarted.mark()
            }
        )
        let task = Task { await runtime.run() }

        await maintenanceGate.waitUntilHeld()
        #expect(focusStarted.value)
        #expect(!usageStarted.value)

        maintenanceGate.release()
        await task.value
        #expect(usageStarted.value)
    }

    @MainActor
    @Test("a failed maintenance attempt still starts usage after the update race ends")
    func failedMaintenanceStillStartsUsage() async {
        let usageStarted = RuntimeFlag()
        let focusStarted = RuntimeFlag()
        let runtime = AgentGridApplicationRuntime(
            maintenance: { false },
            usage: { usageStarted.mark() },
            focus: { focusStarted.mark() }
        )

        await runtime.run()

        #expect(usageStarted.value)
        #expect(focusStarted.value)
    }

    @MainActor
    @Test("app runtime startup defers blocking CLI discovery off the main actor")
    func appRuntimeStartupDefersCLIDiscovery() async {
        let discovery = RuntimeBlockingDirectoryDiscovery()
        defer { discovery.release() }
        let maintenance = CLIMaintenanceModel(
            liveBaseEnvironment: ["PATH": ""],
            liveHomeDirectory: URL(fileURLWithPath: "/isolated-test-home", isDirectory: true),
            directoryContents: discovery.contents(at:)
        )

        #expect(!discovery.wasCalled)

        let runtime = AgentGridApplicationRuntime(
            maintenance: {
                await maintenance.start()
                return maintenance.configuration != nil
            },
            usage: {},
            focus: {}
        )
        let task = Task { await runtime.run() }

        await discovery.waitUntilCalled()
        #expect(!discovery.wasCalledOnMainThread)
        #expect(maintenance.phase == .running(
            CLIMaintenanceProgress(
                completedCount: 0,
                activeKind: nil,
                stage: nil,
                entries: []
            )
        ))

        task.cancel()
        discovery.release()
        await task.value
        #expect(maintenance.phase == .idle)
    }

    @MainActor
    @Test("closing the app cancels provider reads, timer, path monitor, and focus monitors")
    func appCloseCancelsOwnedRuntimeResources() async throws {
        let clock = RuntimeManualClock()
        let postCancelGate = RuntimePostCancelGate()
        defer { postCancelGate.release() }
        let acp = RuntimeCancellationProbe(postCancelGate: postCancelGate)
        let http = RuntimeCancellationProbe()
        let runtimeReturned = RuntimeFlag()
        let pathMonitor = RuntimeFlag()
        var continuation: AsyncStream<UsageLifecycleEvent>.Continuation!
        let events = AsyncStream<UsageLifecycleEvent> { value in
            continuation = value
            value.onTermination = { _ in pathMonitor.mark() }
        }
        let coordinator = CLIUsageRefreshCoordinator(
            clock: clock,
            jitter: { $0 },
            refresh: { providers in
                async let acpRead: Void = acp.wait()
                async let httpRead: Void = http.wait()
                _ = await (acpRead, httpRead)
                return ProviderRefreshOutcome(succeeded: [], failed: providers)
            }
        )

        let focusClient = RuntimeFocusActivationClient()
        let focusController = ApplicationFocusRetentionController(
            clock: clock,
            activationClient: focusClient
        )
        let focusEvents = RuntimeFocusEventSource()
        let focusActivations = RuntimeFocusActivationSource()
        let focusMonitor = FocusIntentMonitor(
            controller: focusController,
            eventSource: focusEvents,
            activationSource: focusActivations,
            accessibilityTrusted: { false }
        )
        let focusLifetime = RuntimeCancellationProbe()
        let runtime = AgentGridApplicationRuntime(
            maintenance: { true },
            usage: {
                await coordinator.run(isActive: true, lifecycleEvents: events)
            },
            focus: {
                focusMonitor.start()
                defer { focusMonitor.stop() }
                await focusLifetime.wait()
            }
        )
        let task = Task {
            await runtime.run()
            runtimeReturned.mark()
        }

        try await runtimeEventually {
            acp.wasStarted
                && http.wasStarted
                && focusLifetime.wasStarted
                && clock.pendingSleeperCount == 1
                && focusEvents.installCount == 2
                && focusActivations.startCount == 1
        }

        task.cancel()
        await postCancelGate.waitUntilHeld()
        await runtimeMainActorBarrier()
        #expect(!runtimeReturned.value)
        postCancelGate.release()
        await task.value

        #expect(acp.wasCancelled)
        #expect(acp.wasFinished)
        #expect(http.wasCancelled)
        #expect(http.wasFinished)
        #expect(focusLifetime.wasCancelled)
        #expect(focusLifetime.wasFinished)
        #expect(pathMonitor.value)
        #expect(clock.pendingSleeperCount == 0)
        #expect(focusEvents.removedTokens.count == 2)
        #expect(focusActivations.stopCount == 1)
        continuation.finish()
    }
}

private final class RuntimeCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let postCancelGate: RuntimePostCancelGate?

    init(postCancelGate: RuntimePostCancelGate? = nil) {
        self.postCancelGate = postCancelGate
    }

    var wasStarted: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var wasFinished: Bool { lock.withLock { finished } }

    func wait() async {
        lock.withLock { started = true }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if cancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                self.cancelled = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume()
        }
        if wasCancelled {
            await postCancelGate?.hold()
        }
        lock.withLock { finished = true }
    }
}

private final class RuntimeBlockingDirectoryDiscovery: @unchecked Sendable {
    private let condition = NSCondition()
    private var called = false
    private var calledOnMainThread = false
    private var released = false
    private var calledContinuation: CheckedContinuation<Void, Never>?

    var wasCalled: Bool {
        condition.withLock { called }
    }

    var wasCalledOnMainThread: Bool {
        condition.withLock { calledOnMainThread }
    }

    func contents(at _: URL) -> [URL] {
        condition.lock()
        called = true
        calledOnMainThread = Thread.isMainThread
        calledContinuation?.resume()
        calledContinuation = nil
        while !released {
            condition.wait()
        }
        condition.unlock()
        return []
    }

    func waitUntilCalled() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = condition.withLock { () -> Bool in
                if called { return true }
                calledContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private final class RuntimePostCancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var released = false
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        let shouldWait = lock.withLock { () -> Bool in
            held = true
            heldContinuation?.resume()
            heldContinuation = nil
            return !released
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if held { return true }
                heldContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}

private final class RuntimeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func mark() { lock.withLock { storage = true } }
}

private final class RuntimeAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var released = false
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        let shouldWait = lock.withLock { () -> Bool in
            held = true
            heldContinuation?.resume()
            heldContinuation = nil
            return !released
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if held { return true }
                heldContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class RuntimeFocusActivationClient: FocusActivationClient {
    let processIdentifier: pid_t = 7
    var isApplicationActive = true
    var isMainWindowVisibleNormal = true
    func activate() {}
    func rekeyMainWindow() {}
}

@MainActor
private final class RuntimeFocusEventSource: FocusEventSource {
    private(set) var installCount = 0
    private(set) var removedTokens: [Int] = []

    func installLocal(
        handler _: @escaping (FocusIntentEvent) -> FocusIntentEvent
    ) -> Int {
        defer { installCount += 1 }
        return installCount
    }

    func installGlobal(
        includeKeyEvents _: Bool,
        handler _: @escaping (FocusIntentEvent) -> Void
    ) -> Int {
        defer { installCount += 1 }
        return installCount
    }

    func remove(_ token: Int) {
        removedTokens.append(token)
    }
}

@MainActor
private final class RuntimeFocusActivationSource: FocusActivationSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler _: @escaping @MainActor @Sendable (pid_t) -> Void) {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private struct RuntimeManualClock: Clock, @unchecked Sendable {
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
}

@MainActor
private func runtimeEventually(
    _ predicate: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
    throw RuntimeIntegrationWaitError.conditionTimedOut
}

private enum RuntimeIntegrationWaitError: Error {
    case conditionTimedOut
}

@MainActor
private func runtimeMainActorBarrier() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
