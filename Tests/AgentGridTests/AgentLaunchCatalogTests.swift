import Foundation
import Testing
@testable import AgentGrid

struct AgentLaunchCatalogTests {
    @Test("Catalog preserves the approved 2x2 pane order")
    func paneOrder() {
        let specs = AgentLaunchCatalog.make(
            workspace: URL(fileURLWithPath: "/work"),
            resolver: StubExecutableResolver()
        )

        #expect(specs.map(\.kind) == [.codex, .claude, .grok, .cursor])
    }

    @Test(
        "Each CLI receives its exact YOLO arguments",
        arguments: [
            (AgentKind.codex, ["--dangerously-bypass-approvals-and-sandbox"]),
            (AgentKind.claude, ["--dangerously-skip-permissions"]),
            (AgentKind.grok, ["--always-approve"]),
            (AgentKind.cursor, ["--yolo"]),
        ]
    )
    func yoloArguments(kind: AgentKind, expected: [String]) throws {
        let specs = AgentLaunchCatalog.make(
            workspace: URL(fileURLWithPath: "/work"),
            resolver: StubExecutableResolver()
        )
        let spec = try #require(specs.first { $0.kind == kind })

        #expect(spec.arguments == expected)
    }

    @Test("Every CLI starts in the shared workspace")
    func workingDirectory() {
        let workspace = URL(fileURLWithPath: "/Volumes/Extreme Pro/Documents/Work")
        let specs = AgentLaunchCatalog.make(
            workspace: workspace,
            resolver: StubExecutableResolver()
        )

        #expect(specs.allSatisfy { $0.workingDirectory == workspace })
    }

    @Test("A missing CLI gets an isolated env error pane without blocking the grid")
    func missingExecutableFallback() throws {
        let specs = AgentLaunchCatalog.make(
            workspace: URL(fileURLWithPath: "/work"),
            resolver: MissingClaudeResolver()
        )
        let claude = try #require(specs.first { $0.kind == .claude })

        #expect(specs.count == 4)
        #expect(claude.executable.path == "/usr/bin/env")
        #expect(claude.arguments == ["claude", "--dangerously-skip-permissions"])
    }
}

private struct StubExecutableResolver: ExecutableResolving {
    func resolve(_ executableName: String) -> URL? {
        URL(fileURLWithPath: "/test-bin/\(executableName)")
    }
}

private struct MissingClaudeResolver: ExecutableResolving {
    func resolve(_ executableName: String) -> URL? {
        guard executableName != "claude" else { return nil }
        return URL(fileURLWithPath: "/test-bin/\(executableName)")
    }
}
