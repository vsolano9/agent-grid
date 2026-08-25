import Foundation

@MainActor
protocol FocusStealApplicationControlling: AnyObject {
    var isActive: Bool { get }
    func deactivate()
    func activate()
}

enum ProgrammaticFocusStealError: Error, Equatable {
    case failedToBecomeInactive
}

@MainActor
final class ProgrammaticFocusStealCoordinator<C: Clock> where C.Duration == Duration {
    private let clock: C
    private let application: FocusStealApplicationControlling
    private let inactivityTimeout: Duration
    private let activationDelay: Duration
    private let pollInterval: Duration
    private let receipt: @MainActor @Sendable (String) -> Void

    init(
        clock: C,
        application: FocusStealApplicationControlling,
        inactivityTimeout: Duration = .seconds(2),
        activationDelay: Duration = .milliseconds(300),
        pollInterval: Duration = .milliseconds(25),
        receipt: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.clock = clock
        self.application = application
        self.inactivityTimeout = inactivityTimeout
        self.activationDelay = activationDelay
        self.pollInterval = pollInterval
        self.receipt = receipt
    }

    func run() async throws {
        application.deactivate()
        let deadline = clock.now.advanced(by: inactivityTimeout)
        while application.isActive, clock.now < deadline {
            try await clock.sleep(for: pollInterval)
        }
        guard !application.isActive else {
            receipt("inactive-precondition-failed")
            throw ProgrammaticFocusStealError.failedToBecomeInactive
        }

        receipt("inactive-precondition-confirmed")
        try await clock.sleep(for: activationDelay)
        try Task.checkCancellation()
        guard !application.isActive else {
            receipt("inactive-precondition-failed")
            throw ProgrammaticFocusStealError.failedToBecomeInactive
        }
        application.activate()
    }
}
