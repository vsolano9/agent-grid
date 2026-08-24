import Foundation
import Testing
@testable import AgentGrid

@Suite("Terminal launch lifecycle")
struct TerminalLaunchGateTests {
    @Test("only the top-left pane receives initial focus even when every CLI is Codex")
    func focusBelongsToPanePosition() {
        let preferences = AgentPanePosition.allCases.map(
            TerminalGridLayoutPolicy.prefersFocus(at:)
        )

        #expect(preferences == [true, false, false, false])
    }

    @Test("launches once only after attachment and layout")
    func launchesOnceWhenReady() {
        var gate = TerminalLaunchGate()

        let unprepared = gate.beginIfReady(
            isWindowPrepared: false,
            isAttached: true,
            width: 500,
            height: 300
        )
        let detached = gate.beginIfReady(
            isWindowPrepared: true,
            isAttached: false,
            width: 500,
            height: 300
        )
        let zeroWidth = gate.beginIfReady(
            isWindowPrepared: true,
            isAttached: true,
            width: 0,
            height: 300
        )
        let zeroHeight = gate.beginIfReady(
            isWindowPrepared: true,
            isAttached: true,
            width: 500,
            height: 0
        )
        let ready = gate.beginIfReady(
            isWindowPrepared: true,
            isAttached: true,
            width: 500,
            height: 300
        )
        let secondAttempt = gate.beginIfReady(
            isWindowPrepared: true,
            isAttached: true,
            width: 500,
            height: 300
        )

        #expect(!unprepared)
        #expect(!detached)
        #expect(!zeroWidth)
        #expect(!zeroHeight)
        #expect(ready)
        #expect(!secondAttempt)
    }

    @Test("preferred pane claims focus only when its grid becomes active")
    func claimsFocusOnActivation() {
        var gate = TerminalActivationGate()

        let initiallyInactive = gate.shouldClaimFocus(isActive: false, prefersFocus: true)
        let becameActive = gate.shouldClaimFocus(isActive: true, prefersFocus: true)
        let remainedActive = gate.shouldClaimFocus(isActive: true, prefersFocus: true)
        let becameInactive = gate.shouldClaimFocus(isActive: false, prefersFocus: true)
        let reactivated = gate.shouldClaimFocus(isActive: true, prefersFocus: true)

        #expect(!initiallyInactive)
        #expect(becameActive)
        #expect(!remainedActive)
        #expect(!becameInactive)
        #expect(reactivated)
    }

    @Test("non-preferred panes never claim focus")
    func ignoresNonPreferredPane() {
        var gate = TerminalActivationGate()

        let initiallyActive = gate.shouldClaimFocus(isActive: true, prefersFocus: false)
        let becameInactive = gate.shouldClaimFocus(isActive: false, prefersFocus: false)
        let reactivated = gate.shouldClaimFocus(isActive: true, prefersFocus: false)

        #expect(!initiallyActive)
        #expect(!becameInactive)
        #expect(!reactivated)
    }

    @Test("child reaper forwards the exact PID off the caller")
    func reapsExactProcess() async {
        let observedPID = await withCheckedContinuation { continuation in
            let reaper = ChildProcessReaper(
                queue: DispatchQueue(label: "AgentGridTests.ChildProcessReaper"),
                waitForExit: { pid in
                    continuation.resume(returning: pid)
                }
            )

            reaper.reap(42)
        }

        #expect(observedPID == 42)
    }
}
