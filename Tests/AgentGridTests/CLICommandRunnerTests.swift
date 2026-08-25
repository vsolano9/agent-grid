import Darwin
import Foundation
import Testing
@testable import AgentGrid

struct CLICommandRunnerTests {
    @Test("Runner captures bounded version output")
    func capturesOutput() async {
        let runner = CLICommandRunner(environment: [:])

        let result = await runner.run(
            CLICommand(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["version 1.2.3\n"],
                capturesOutput: true
            )
        )

        #expect(result == .exited(status: 0, output: "version 1.2.3\n"))
    }

    @Test("Runner preserves a nonzero exit status")
    func nonzeroExit() async {
        let runner = CLICommandRunner(environment: [:])

        let result = await runner.run(
            CLICommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        )

        #expect(result == .exited(status: 1, output: ""))
    }

    @Test("Runner reports a missing executable without trapping")
    func missingExecutable() async {
        let runner = CLICommandRunner(environment: [:])

        let result = await runner.run(
            CLICommand(executable: URL(fileURLWithPath: "/missing/agent-grid-cli"), arguments: [])
        )

        guard case .failedToStart = result else {
            Issue.record("Expected failedToStart, got \(result)")
            return
        }
    }

    @Test("Runner terminates a command at its timeout")
    func timeout() async {
        let runner = CLICommandRunner(environment: [:], pollInterval: .milliseconds(5))

        let result = await runner.run(
            CLICommand(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .milliseconds(20)
            )
        )

        #expect(result == .timedOut)
    }

    @Test("Runner propagates task cancellation to the child")
    func cancellation() async {
        let runner = CLICommandRunner(environment: [:], pollInterval: .milliseconds(5))
        let task = Task {
            await runner.run(
                CLICommand(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"]
                )
            )
        }

        await Task.yield()
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    @Test("A pre-cancelled task never starts its command")
    func preCancelledTaskDoesNotSpawn() async throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentGridPreCancelled-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let runner = CLICommandRunner(environment: [:])
        let task = Task {
            await Task.yield()
            return await runner.run(
                CLICommand(
                    executable: URL(fileURLWithPath: "/usr/bin/touch"),
                    arguments: [sentinel.path]
                )
            )
        }

        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Cancellation synchronously terminates a ready updater descendant")
    func cancellationTerminatesDescendants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentGridRunnerTree-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("child-pid")
        let childReady = root.appendingPathComponent("child-ready")
        let sentinel = root.appendingPathComponent("survived")
        let runner = CLICommandRunner(environment: [:], pollInterval: .milliseconds(5))

        let task = Task {
            await runner.run(
                CLICommand(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "/bin/sh -c 'trap \"\" HUP TERM; echo $$ > \"$1\"; /usr/bin/touch \"$2\"; /bin/sleep 5; /usr/bin/touch \"$3\"' agentgrid-child \"$1\" \"$2\" \"$3\" & /bin/sleep 5",
                        "agentgrid-parent",
                        childPIDFile.path,
                        childReady.path,
                        sentinel.path,
                    ]
                )
            )
        }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: childReady.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: childReady.path))
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(childPIDText))

        task.cancel()
        #expect(await task.value == .cancelled)

        for _ in 0..<200 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}
