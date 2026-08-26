#if os(macOS)
import Dispatch
import Foundation
import Testing

@testable import SwiftTerm

@Suite("Local process termination")
struct LocalProcessTerminationTests {
    @Test("waitpid retries EINTR, reaps once, and publishes one completion", .timeLimit(.minutes(1)))
    func interruptedWaitRetriesBeforeCompleting() async {
        let waitState = WaitAttemptState()
        let delegate = LocalProcessTerminationDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTermTests.LocalProcessTermination"),
            waitForExit: { pid in
                if waitState.recordAttempt() == 1 {
                    return LocalProcessWaitAttempt(pid: -1, status: 0, errorNumber: EINTR)
                }
                var status: Int32 = 0
                let waitedPID = waitpid(pid, &status, 0)
                return LocalProcessWaitAttempt(
                    pid: waitedPID,
                    status: status,
                    errorNumber: waitedPID == -1 ? errno : 0
                )
            }
        )

        process.startProcess(executable: "/usr/bin/true")
        let leaderPID = process.shellPid
        guard leaderPID > 0 else {
            Issue.record("expected startProcess to publish a leader PID")
            return
        }
        let result = await withCheckedContinuation { continuation in
            process.terminate { terminationResult in
                continuation.resume(returning: terminationResult)
            }
        }

        guard case .reaped = result else {
            Issue.record("expected LocalProcess to reap its leader, got \(result)")
            return
        }
        #expect(waitState.attemptCount == 2)
        #expect(delegate.terminationCount == 1)

        var secondStatus: Int32 = 0
        errno = 0
        #expect(waitpid(leaderPID, &secondStatus, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }
}

private final class WaitAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func recordAttempt() -> Int {
        lock.withLock {
            attempts += 1
            return attempts
        }
    }
}

private final class LocalProcessTerminationDelegate: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var terminations = 0

    var terminationCount: Int {
        lock.withLock { terminations }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock { terminations += 1 }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {}

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}
#endif
