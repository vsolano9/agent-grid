import Testing
@testable import AgentGrid

@Suite("Terminal launch lifecycle")
struct TerminalLaunchGateTests {
    @Test("launches once only after attachment and layout")
    func launchesOnceWhenReady() {
        var gate = TerminalLaunchGate()

        let detached = gate.beginIfReady(isAttached: false, width: 500, height: 300)
        let zeroWidth = gate.beginIfReady(isAttached: true, width: 0, height: 300)
        let zeroHeight = gate.beginIfReady(isAttached: true, width: 500, height: 0)
        let ready = gate.beginIfReady(isAttached: true, width: 500, height: 300)
        let secondAttempt = gate.beginIfReady(isAttached: true, width: 500, height: 300)

        #expect(!detached)
        #expect(!zeroWidth)
        #expect(!zeroHeight)
        #expect(ready)
        #expect(!secondAttempt)
    }
}
