import Foundation
import Darwin
import AppKit
import SwiftTerm
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

    @MainActor
    @Test("inactive terminal views stop drawing without terminating their session")
    func inactiveTerminalViewsAreHidden() {
        let terminal = LaunchingTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: .default
        )

        terminal.updateGridActivation(isActive: false, prefersFocus: false)
        #expect(terminal.isHidden)

        terminal.updateGridActivation(isActive: true, prefersFocus: false)
        #expect(terminal.isHidden == false)
    }

    @Test("terminal cleanup reaps its leader and terminates normal and setsid descendants", .timeLimit(.minutes(1)))
    func cleanupTerminatesTrackedProcessTree() async throws {
        let fixture = try ProcessGroupFixture.start()
        defer { fixture.forceCleanup() }

        try await fixture.waitUntilReady()
        let cleanup = ProcessTreeTerminator.live.beginTermination(
            rootPID: fixture.processID
        ) { completion in
            let processID = fixture.processID
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(processID, &status, 0)
                } while result == -1 && errno == EINTR
                if result == processID {
                    completion(.reaped(status: status))
                } else if errno == ECHILD {
                    completion(.reapedByAnotherOwner)
                } else {
                    completion(.waitFailed(errno: errno))
                }
            }
        }
        let result = await cleanup.value

        #expect(result.completed)
        #expect(result.descendantsObserved >= 3)
        #expect(result.survivors.isEmpty)
        if case .reaped = result.leader {
            // Expected: the fixture closure is the sole waitpid owner.
        } else {
            Issue.record("The direct child leader was not reaped by its owner: \(result.leader)")
        }
        #expect(fixture.leaderWasReaped())
    }

    @Test("cleanup refuses to signal a recycled PID whose start identity changed")
    func cleanupDoesNotSignalRecycledPID() {
        let recorded = ProcessIdentity(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 200,
            userID: 501,
            parentPID: 1,
            processGroupID: 42
        )
        let recycled = ProcessIdentity(
            pid: 42,
            startSeconds: 101,
            startMicroseconds: 0,
            userID: 501,
            parentPID: 1,
            processGroupID: 42
        )
        var signalCount = 0

        let didSignal = ProcessTreeTerminator.signalIfIdentityMatches(
            recorded,
            signal: SIGKILL,
            currentIdentity: { _ in recycled },
            sendSignal: { _, _ in
                signalCount += 1
                return 0
            }
        )

        #expect(!didSignal)
        #expect(signalCount == 0)
    }
}

private struct ProcessGroupFixture {
    let processID: pid_t
    let readyFile: URL

    static func start() throws -> Self {
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgrid-process-group-\(UUID().uuidString)")
        let command = "trap '' TERM; "
            + "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & child_one=$!; "
            + "/usr/bin/perl -MPOSIX -e 'POSIX::setpgid(0,0); $SIG{TERM}=sub { my $pid=fork(); if ($pid==0) { POSIX::setsid(); $SIG{TERM}=sub {}; while (1) { sleep 1 } } open(my $file, \">>\", $ARGV[0]); print $file \" $pid\"; close($file); sleep 2; exit 0 }; while (1) { sleep 1 }' \"$1\" & child_two=$!; "
            + "echo \"$child_one $child_two\" > \"$1\"; wait"
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw FixtureError.couldNotCreateProcessGroup
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw FixtureError.couldNotCreateProcessGroup
        }

        let nullPath = "/dev/null"
        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            nullPath,
            O_RDONLY,
            0
        ) == 0,
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                nullPath,
                O_WRONLY,
                0
            ) == 0,
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                nullPath,
                O_WRONLY,
                0
            ) == 0 else {
            throw FixtureError.couldNotCreateProcessGroup
        }

        let arguments = CStringVector([
            "/bin/sh", "-c", command, "agentgrid-fixture", readyFile.path
        ])
        let environment = CStringVector(
            ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        )
        defer {
            arguments.deallocate()
            environment.deallocate()
        }
        var processID: pid_t = 0
        let spawnResult = posix_spawn(
            &processID,
            "/bin/sh",
            &fileActions,
            &attributes,
            arguments.pointer,
            environment.pointer
        )
        guard spawnResult == 0 else {
            throw FixtureError.couldNotCreateProcessGroup
        }
        return Self(processID: processID, readyFile: readyFile)
    }

    func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: readyFile.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.didNotBecomeReady
    }

    func leaderWasReaped() -> Bool {
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        return result == -1 && errno == ECHILD
    }

    func forceCleanup() {
        _ = Darwin.kill(-processID, SIGKILL)
        if let contents = try? String(contentsOf: readyFile, encoding: .utf8) {
            for value in contents.split(whereSeparator: \.isWhitespace) {
                if let pid = pid_t(String(value)) {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
        }
        _ = Darwin.kill(processID, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(processID, &status, WNOHANG)
        _ = try? FileManager.default.removeItem(at: readyFile)
    }

    private enum FixtureError: Error {
        case couldNotCreateProcessGroup
        case didNotBecomeReady
    }
}

private final class CStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    func deallocate() {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
