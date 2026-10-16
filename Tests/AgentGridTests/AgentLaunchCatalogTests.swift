import Foundation
import Testing
@testable import AgentGrid

struct AgentLaunchCatalogTests {
    @Test("A selection always contains exactly four pane assignments")
    func selectionCardinality() {
        #expect(AgentGridSelection(agents: [.codex, .claude, .grok]) == nil)
        #expect(AgentGridSelection(agents: [.codex, .claude, .grok, .cursor]) != nil)
        #expect(AgentGridSelection(agents: [.codex, .claude, .grok, .cursor, .codex]) == nil)
    }

    @Test("Catalog expands duplicate CLI choices in exact pane order")
    func duplicateSelection() throws {
        let workspace = URL(fileURLWithPath: "/work")
        let selection = try #require(
            AgentGridSelection(agents: Array(repeating: .codex, count: 4))
        )

        let specs = AgentLaunchCatalog.make(
            selection: selection,
            workspace: workspace,
            resolver: StubExecutableResolver()
        )

        #expect(specs.map(\.kind) == [.codex, .codex, .codex, .codex])
        #expect(specs.allSatisfy { $0.executable.path == "/test-bin/codex" })
        #expect(specs.allSatisfy {
            $0.arguments == ["--dangerously-bypass-approvals-and-sandbox"]
        })
        #expect(specs.allSatisfy { $0.workingDirectory == workspace })
    }

    @Test("Hermes Agent can occupy any terminal pane in YOLO mode")
    func hermesSelection() throws {
        let workspace = URL(fileURLWithPath: "/work")
        let selection = try #require(
            AgentGridSelection(agents: [.hermes, .codex, .hermes, .claude])
        )

        let specs = AgentLaunchCatalog.make(
            selection: selection,
            workspace: workspace,
            resolver: StubExecutableResolver()
        )

        #expect(specs.map(\.kind) == [.hermes, .codex, .hermes, .claude])
        #expect(specs[0].executable.path == "/test-bin/hermes")
        #expect(specs[0].arguments == ["--yolo"])
        #expect(specs[2].arguments == ["--yolo"])
    }

    @Test("Live configuration expands a frozen duplicate selection without re-resolving")
    func configurationExpandsSelection() throws {
        let workspace = URL(fileURLWithPath: "/work")
        let catalog = AgentLaunchCatalog.make(
            workspace: workspace,
            resolver: StubExecutableResolver()
        )
        let configuration = AgentGridConfiguration(
            catalog: catalog,
            environment: ["TERM": "xterm-256color"],
            workspace: workspace
        )
        let selection = try #require(
            AgentGridSelection(agents: Array(repeating: .codex, count: 4))
        )

        let specs = configuration.launchSpecs(for: selection)

        #expect(specs.map(\.kind) == [.codex, .codex, .codex, .codex])
        #expect(specs.allSatisfy { $0.executable.path == "/test-bin/codex" })
        #expect(specs.allSatisfy { $0.workingDirectory == workspace })
    }

    @Test("Configuration applies a grid-specific working directory to every pane")
    func configurationAppliesGridWorkspace() throws {
        let defaultWorkspace = URL(fileURLWithPath: "/work")
        let gridWorkspace = URL(fileURLWithPath: "/work/custom-grid")
        let catalog = AgentLaunchCatalog.make(
            workspace: defaultWorkspace,
            resolver: StubExecutableResolver()
        )
        let configuration = AgentGridConfiguration(
            catalog: catalog,
            environment: [:],
            workspace: defaultWorkspace
        )

        let specs = configuration.launchSpecs(
            for: .standard,
            workingDirectory: gridWorkspace
        )

        #expect(specs.count == 4)
        #expect(specs.allSatisfy { $0.workingDirectory == gridWorkspace })
    }

    @Test("Catalog preserves the approved 2x2 pane order")
    func paneOrder() {
        let specs = AgentLaunchCatalog.make(
            workspace: URL(fileURLWithPath: "/work"),
            resolver: StubExecutableResolver()
        )

        #expect(specs.map(\.kind) == [.codex, .claude, .grok, .cursor])
    }

    @Test("Supported catalog covers every selectable CLI, including Hermes")
    func supportedCatalog() throws {
        let workspace = URL(fileURLWithPath: "/work")
        let catalog = AgentLaunchCatalog.makeSupported(
            workspace: workspace,
            resolver: StubExecutableResolver()
        )
        let configuration = AgentGridConfiguration(
            catalog: catalog,
            environment: [:],
            workspace: workspace
        )
        let selection = try #require(
            AgentGridSelection(agents: [.hermes, .codex, .claude, .grok])
        )

        #expect(catalog.map(\.kind) == AgentKind.allCases)
        #expect(configuration.launchSpecs(for: selection).map(\.kind) == [
            .hermes, .codex, .claude, .grok,
        ])
    }

    @Test(
        "Each CLI receives its exact YOLO arguments",
        arguments: [
            (AgentKind.codex, ["--dangerously-bypass-approvals-and-sandbox"]),
            (AgentKind.claude, ["--dangerously-skip-permissions"]),
            (AgentKind.grok, ["--always-approve"]),
            (AgentKind.cursor, ["--yolo"]),
            (AgentKind.hermes, ["--yolo"]),
        ]
    )
    func yoloArguments(kind: AgentKind, expected: [String]) throws {
        let selection = try #require(
            AgentGridSelection(agents: [kind, .codex, .claude, .grok])
        )
        let specs = AgentLaunchCatalog.make(
            selection: selection,
            workspace: URL(fileURLWithPath: "/work"),
            resolver: StubExecutableResolver()
        )
        let spec = try #require(specs.first { $0.kind == kind })

        #expect(spec.arguments == expected)
    }

    @Test("Every CLI starts in the shared workspace")
    func workingDirectory() {
        let workspace = URL(fileURLWithPath: "/Users/test/Projects")
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
