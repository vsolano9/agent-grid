import Foundation
import Testing
@testable import AgentGrid

@Suite(.serialized)
struct LiveProviderUsageTests {
    @Test(
        "Installed Claude CLI emits parseable usage",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/AgentGridLiveUsageTests.enabled"
        ))
    )
    func installedClaudeCLIEmitsParseableUsage() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var baseEnvironment = ProcessInfo.processInfo.environment
        baseEnvironment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
        baseEnvironment["HOME"] = home.path
        baseEnvironment["USER"] = NSUserName()
        let environment = TerminalEnvironment.make(base: baseEnvironment, homeDirectory: home)
        let outcome = await CLICommandRunner(environment: environment).run(CLICommand(
            executable: home.appendingPathComponent(".local/bin/claude"),
            arguments: ["/usage"],
            timeout: .seconds(15),
            capturesOutput: true
        ))

        guard case .exited(let status, let output) = outcome else {
            Issue.record("Claude /usage did not exit normally: \(String(describing: outcome))")
            return
        }
        #expect(status == 0)
        do {
            let observation = try ClaudeUsageParser.parseObservation(from: Data(output.utf8))
            #expect(observation.windows.contains { $0.id.key == "five_hour" })
        } catch {
            let hasCurrentSession = output.contains("Current session")
            Issue.record("Claude /usage output was not parseable (bytes=\(output.utf8.count), currentSession=\(hasCurrentSession)).")
        }
    }

    @Test(
        "Signed-in provider accounts expose live quota percentages",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/AgentGridLiveUsageTests.enabled"
        ))
    )
    func signedInAccountsExposeQuota() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = nil
        environment["HOME"] = home.path
        environment["USER"] = NSUserName()
        let snapshots = try await CLIUsageService.live(
            environment: environment,
            homeDirectory: home
        ).fetch()

        for kind in CLIUsageService.displayedKinds {
            guard let snapshot = snapshots.first(where: { $0.provider == kind }),
                  snapshot.state == .available,
                  snapshot.windows.contains(where: { $0.freshness == .fresh }) else {
                Issue.record("\(kind.displayName) did not return live quota windows.")
                continue
            }
            #expect(snapshot.windows.allSatisfy { (0 ... 100).contains($0.remainingPercent) })
            #expect(snapshot.windows.allSatisfy { window in
                window.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true
            })
        }
    }
}
