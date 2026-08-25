import Foundation
import Testing
@testable import AgentGrid

@MainActor
@Suite("Programmatic focus-steal fixture")
struct ProgrammaticFocusStealCoordinatorTests {
    @Test("programmatic activation occurs only after the fixture proves it is inactive")
    func activationRequiresInactivePrecondition() async throws {
        let application = FakeFocusStealApplication(deactivationSucceeds: true)
        var receipts: [String] = []
        let coordinator = ProgrammaticFocusStealCoordinator(
            clock: ContinuousClock(),
            application: application,
            inactivityTimeout: .zero,
            activationDelay: .zero,
            pollInterval: .zero,
            receipt: { receipts.append($0) }
        )

        try await coordinator.run()

        #expect(application.deactivationCount == 1)
        #expect(application.activationCount == 1)
        #expect(application.wasInactiveWhenActivated)
        #expect(receipts == ["inactive-precondition-confirmed"])
    }

    @Test("failed inactivity precondition is observable and never activates")
    func failedPreconditionDoesNotActivate() async {
        let application = FakeFocusStealApplication(deactivationSucceeds: false)
        var receipts: [String] = []
        let coordinator = ProgrammaticFocusStealCoordinator(
            clock: ContinuousClock(),
            application: application,
            inactivityTimeout: .zero,
            activationDelay: .zero,
            pollInterval: .zero,
            receipt: { receipts.append($0) }
        )

        await #expect(throws: ProgrammaticFocusStealError.failedToBecomeInactive) {
            try await coordinator.run()
        }
        #expect(application.activationCount == 0)
        #expect(receipts == ["inactive-precondition-failed"])
    }
}

@MainActor
private final class FakeFocusStealApplication: FocusStealApplicationControlling {
    private let deactivationSucceeds: Bool
    private(set) var isActive = true
    private(set) var deactivationCount = 0
    private(set) var activationCount = 0
    private(set) var wasInactiveWhenActivated = false

    init(deactivationSucceeds: Bool) {
        self.deactivationSucceeds = deactivationSucceeds
    }

    func deactivate() {
        deactivationCount += 1
        if deactivationSucceeds { isActive = false }
    }

    func activate() {
        wasInactiveWhenActivated = !isActive
        activationCount += 1
        isActive = true
    }
}
