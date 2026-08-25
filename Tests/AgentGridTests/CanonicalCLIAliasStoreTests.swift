import Foundation
import Testing
@testable import AgentGrid

struct CanonicalCLIAliasStoreTests {
    @Test("Store creates a canonical link to a PATH executable")
    func createsAlias() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeExecutable(named: "codex")
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let alias = try await store.repairAlias(for: fixture.item(kind: .codex))

        #expect(alias == fixture.alias(named: "codex"))
        #expect(alias.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }

    @Test("Store atomically replaces a broken canonical link")
    func replacesBrokenAlias() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeExecutable(named: "claude")
        let alias = fixture.alias(named: "claude")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.root.appendingPathComponent("missing-claude")
        )
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let repaired = try await store.repairAlias(for: fixture.item(kind: .claude))

        #expect(repaired.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
        #expect(try FileManager.default.contentsOfDirectory(atPath: alias.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".agentgrid-alias-") }
            .isEmpty)
    }

    @Test("Store replaces a wrong executable at the canonical path")
    func replacesCanonicalExecutable() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let alias = fixture.alias(named: "cursor-agent")
        try fixture.makeExecutable(at: alias)
        let target = try fixture.makeExecutable(named: "cursor-agent")
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let repaired = try await store.repairAlias(for: fixture.item(kind: .cursor))

        #expect(repaired == alias)
        #expect(FileManager.default.isSymbolicLink(at: alias))
        #expect(repaired.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }

    @Test("Store preserves a working relative canonical link")
    func preservesRelativeAlias() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeExecutable(named: "grok")
        let alias = fixture.alias(named: "grok")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let relativeTarget = "../../../tools/grok"
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: relativeTarget
        )
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let repaired = try await store.repairAlias(for: fixture.item(kind: .grok))

        #expect(repaired.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }

    @Test("Store refuses to replace a directory at an alias path")
    func refusesDirectory() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.makeExecutable(named: "grok")
        try FileManager.default.createDirectory(
            at: fixture.alias(named: "grok"),
            withIntermediateDirectories: true
        )
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        await #expect(throws: CLIAliasError.destinationIsDirectory) {
            try await store.repairAlias(for: fixture.item(kind: .grok))
        }
    }

    @Test("Store rejects a self-referential alias")
    func rejectsSelfReference() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let alias = fixture.alias(named: "codex")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: alias)
        let store = CanonicalCLIAliasStore(homeDirectory: fixture.home, environment: [:])

        await #expect(throws: CLIAliasError.selfReferentialTarget) {
            try await store.repairAlias(for: fixture.item(kind: .codex))
        }
    }

    @Test("Store replaces a working alias that points to the wrong CLI")
    func replacesWrongCLIAlias() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let expected = try fixture.makeExecutable(named: "codex")
        let wrong = try fixture.makeExecutable(named: "claude")
        let alias = fixture.alias(named: "codex")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: wrong)
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let repaired = try await store.repairAlias(for: fixture.item(kind: .codex))

        #expect(repaired.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
    }

    @Test("Store links to a stable launcher instead of pinning its current target")
    func preservesStableLauncherIndirection() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let version = try fixture.makeExecutable(named: "grok-version")
        let stable = fixture.tools.appendingPathComponent("grok")
        try FileManager.default.createSymbolicLink(at: stable, withDestinationURL: version)
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        let alias = try await store.repairAlias(for: fixture.item(kind: .grok))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == stable.path)
    }

    @Test("Store discovers the newest installed Cursor Agent version")
    func discoversNewestCursorVersion() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let versions = fixture.home.appendingPathComponent(
            ".local/share/cursor-agent/versions",
            isDirectory: true
        )
        let older = versions.appendingPathComponent("2026.08.01/cursor-agent")
        let newest = versions.appendingPathComponent("2026.08.11/cursor-agent")
        try fixture.makeExecutable(at: older)
        try fixture.makeExecutable(at: newest)
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": ""]
        )

        let alias = try await store.repairAlias(for: fixture.item(kind: .cursor))
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)

        #expect(
            URL(fileURLWithPath: destination).resolvingSymlinksInPath()
                == newest.resolvingSymlinksInPath()
        )
    }

    @Test("Store discovers Hermes inside its managed virtual environment")
    func discoversHermesVirtualEnvironment() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let hermes = fixture.home.appendingPathComponent(
            ".hermes/hermes-agent/venv/bin/hermes",
            isDirectory: false
        )
        try fixture.makeExecutable(
            at: hermes,
            contents: Data("#!/bin/sh\ntest -z \"${PYTHONHOME+x}\" && test -z \"${PYTHONPATH+x}\"\n".utf8)
        )
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": ""]
        )

        let alias = try await store.repairAlias(for: fixture.item(kind: .hermes))

        #expect(!FileManager.default.isSymbolicLink(at: alias))
        let outcome = await CLICommandRunner(
            environment: ["PYTHONHOME": "/tmp", "PYTHONPATH": "/tmp"]
        ).run(CLICommand(executable: alias, arguments: ["--version"]))
        #expect(outcome.succeeded)
    }

    @Test("Store preserves a verified provider fallback when a new candidate is broken")
    func preservesVerifiedFallback() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makeExecutable(named: "codex")
        let fallback = fixture.root.appendingPathComponent("old/codex")
        try fixture.makeExecutable(at: fallback)
        let alias = fixture.alias(named: "codex")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fallback)
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path],
            verifiesExecutable: { $0 == alias }
        )

        let repaired = try await store.repairAlias(for: fixture.item(kind: .codex))

        #expect(candidate != fallback)
        #expect(repaired.resolvingSymlinksInPath() == fallback.resolvingSymlinksInPath())
    }

    @Test("Store rejects a candidate symlink chain that depends on its alias")
    func rejectsIndirectSelfReference() async throws {
        let fixture = try AliasFixture()
        defer { fixture.cleanUp() }
        let fallback = fixture.root.appendingPathComponent("old/codex")
        try fixture.makeExecutable(at: fallback)
        let alias = fixture.alias(named: "codex")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fallback)
        try FileManager.default.createSymbolicLink(
            at: fixture.tools.appendingPathComponent("codex"),
            withDestinationURL: alias
        )
        let store = CanonicalCLIAliasStore(
            homeDirectory: fixture.home,
            environment: ["PATH": fixture.tools.path]
        )

        await #expect(throws: CLIAliasError.selfReferentialTarget) {
            try await store.repairAlias(for: fixture.item(kind: .codex))
        }
    }
}

private struct AliasFixture {
    let root: URL
    let home: URL
    let tools: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentGridAliasTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    }

    func item(kind: AgentKind) -> CLIMaintenanceItem {
        CLIMaintenanceItem(
            kind: kind,
            aliasURL: alias(named: kind.executableName),
            updateCommand: nil
        )
    }

    func alias(named name: String) -> URL {
        home.appendingPathComponent(".local/bin/\(name)", isDirectory: false)
    }

    func makeExecutable(named name: String) throws -> URL {
        let url = tools.appendingPathComponent(name, isDirectory: false)
        try makeExecutable(at: url)
        return url
    }

    func makeExecutable(at url: URL, contents: Data = Data("fixture".utf8)) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: url.path, contents: contents))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension FileManager {
    func isSymbolicLink(at url: URL) -> Bool {
        (try? destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
