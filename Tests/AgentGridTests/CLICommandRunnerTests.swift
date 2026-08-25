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

    @Test("Timeout terminates updater descendants before they can mutate files")
    func timeoutTerminatesDescendants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentGridRunnerTree-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("survived")
        let runner = CLICommandRunner(environment: [:], pollInterval: .milliseconds(5))

        let result = await runner.run(
            CLICommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "(trap '' HUP TERM; sleep 0.15; /usr/bin/touch \"$1\") & sleep 5",
                    "agentgrid-test",
                    sentinel.path,
                ],
                timeout: .milliseconds(30)
            )
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(result == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}
