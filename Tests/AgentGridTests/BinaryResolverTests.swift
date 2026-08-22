import Foundation
import Testing
@testable import AgentGrid

struct BinaryResolverTests {
    @Test("PATH order determines executable precedence")
    func pathPrecedence() throws {
        let resolver = BinaryResolver(
            environment: ["PATH": "/first:/second"],
            homeDirectory: URL(fileURLWithPath: "/home/test"),
            isExecutable: { $0 == "/second/codex" }
        )

        let resolved = try #require(resolver.resolve("codex"))
        #expect(resolved.path == "/second/codex")
    }

    @Test("Non-executable files are ignored")
    func ignoresNonExecutables() {
        let resolver = BinaryResolver(
            environment: ["PATH": "/first"],
            homeDirectory: URL(fileURLWithPath: "/home/test"),
            isExecutable: { _ in false }
        )

        #expect(resolver.resolve("codex") == nil)
    }

    @Test("Finder-safe user bin folders are searched when PATH is minimal")
    func searchesUserFallbacks() throws {
        let resolver = BinaryResolver(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: URL(fileURLWithPath: "/home/test"),
            isExecutable: { $0 == "/home/test/.local/bin/cursor-agent" }
        )

        let resolved = try #require(resolver.resolve("cursor-agent"))
        #expect(resolved.path == "/home/test/.local/bin/cursor-agent")
    }
}
