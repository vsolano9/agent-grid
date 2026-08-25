import Darwin
import Foundation

actor CanonicalCLIAliasStore: CLIAliasMaintaining {
    private let homeDirectory: URL
    private let locator: CLIExecutableLocator
    private let verifiesExecutable: @Sendable (URL) async -> Bool
    private let fileManager = FileManager.default

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verifiesExecutable: @escaping @Sendable (URL) async -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.homeDirectory = homeDirectory
        locator = CLIExecutableLocator(
            homeDirectory: homeDirectory,
            environment: environment
        )
        self.verifiesExecutable = verifiesExecutable
    }

    func repairAlias(for item: CLIMaintenanceItem) async throws -> URL {
        let canonicalDirectory = homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .standardizedFileURL
        let aliasURL = item.aliasURL.standardizedFileURL

        guard aliasURL.deletingLastPathComponent() == canonicalDirectory else {
            throw CLIAliasError.fileSystem("Alias is outside the canonical directory")
        }

        try fileManager.createDirectory(
            at: canonicalDirectory,
            withIntermediateDirectories: true
        )

        let existingDestination = symbolicLinkDestination(at: aliasURL)
        if let destination = existingDestination {
            let directDestination = directDestination(destination, relativeTo: aliasURL)
            guard directDestination.standardizedFileURL != aliasURL else {
                throw CLIAliasError.selfReferentialTarget
            }
        } else if fileManager.fileExists(atPath: aliasURL.path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: aliasURL.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                throw CLIAliasError.destinationIsDirectory
            }
        }

        if item.kind == .hermes,
           isHermesLauncher(at: aliasURL),
           await verifiesExecutable(aliasURL) {
            return aliasURL
        }

        guard let target = locator.locate(item.kind) else {
            throw CLIAliasError.noExecutable
        }
        guard target.standardizedFileURL != aliasURL else {
            throw CLIAliasError.selfReferentialTarget
        }
        guard !linkChainDependsOnAlias(from: target, aliasURL: aliasURL) else {
            throw CLIAliasError.selfReferentialTarget
        }

        guard await verifiesExecutable(target) else {
            if let existingDestination,
               isPlausibleTarget(existingDestination, for: item.kind, aliasURL: aliasURL),
               await verifiesExecutable(aliasURL) {
                return aliasURL
            }
            throw CLIAliasError.verificationFailed
        }

        if item.kind == .hermes {
            try replaceHermesLauncher(at: aliasURL, target: target)
        } else {
            try replaceAlias(at: aliasURL, with: target)
        }
        return aliasURL
    }

    private func linkChainDependsOnAlias(from start: URL, aliasURL: URL) -> Bool {
        var current = start.standardizedFileURL
        var visited = Set<String>()

        for _ in 0..<64 {
            if current == aliasURL.standardizedFileURL { return true }
            guard visited.insert(current.path).inserted else { return true }
            guard let destination = symbolicLinkDestination(at: current) else { return false }
            current = directDestination(destination, relativeTo: current)
        }
        return true
    }

    private func isPlausibleTarget(
        _ destination: String,
        for kind: AgentKind,
        aliasURL: URL
    ) -> Bool {
        let target = directDestination(destination, relativeTo: aliasURL)
        guard !linkChainDependsOnAlias(from: target, aliasURL: aliasURL) else { return false }
        let path = target.path.lowercased()
        let name = target.lastPathComponent.lowercased()

        switch kind {
        case .codex:
            return name == "codex" || path.contains("/@openai/codex/")
        case .claude:
            return name.hasPrefix("claude") || path.contains("/@anthropic-ai/claude-code/")
        case .grok:
            return name.hasPrefix("grok") || path.contains("/.grok/")
        case .cursor:
            return name == "cursor-agent" || path.contains("/cursor-agent/")
        case .hermes:
            return name == "hermes" || path.contains("/.hermes/")
        }
    }

    private func isHermesLauncher(at url: URL) -> Bool {
        guard symbolicLinkDestination(at: url) == nil,
              fileManager.isExecutableFile(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return contents.contains("unset PYTHONHOME")
            && contents.contains("unset PYTHONPATH")
            && contents.contains("/.hermes/hermes-agent/")
    }

    private func replaceAlias(at aliasURL: URL, with target: URL) throws {
        let temporaryURL = aliasURL.deletingLastPathComponent().appendingPathComponent(
            ".agentgrid-alias-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            try fileManager.createSymbolicLink(at: temporaryURL, withDestinationURL: target)
        } catch {
            throw CLIAliasError.fileSystem(error.localizedDescription)
        }

        if Darwin.rename(temporaryURL.path, aliasURL.path) != 0 {
            throw CLIAliasError.fileSystem(String(cString: strerror(errno)))
        }
    }

    private func replaceHermesLauncher(at aliasURL: URL, target: URL) throws {
        let temporaryURL = aliasURL.deletingLastPathComponent().appendingPathComponent(
            ".agentgrid-alias-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let quotedTarget = "'\(target.path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        let launcher = """
        #!/bin/sh
        unset PYTHONHOME
        unset PYTHONPATH
        exec \(quotedTarget) "$@"

        """
        do {
            try Data(launcher.utf8).write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
        } catch {
            throw CLIAliasError.fileSystem(error.localizedDescription)
        }

        if Darwin.rename(temporaryURL.path, aliasURL.path) != 0 {
            throw CLIAliasError.fileSystem(String(cString: strerror(errno)))
        }
    }

    private func symbolicLinkDestination(at url: URL) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    private func directDestination(_ destination: String, relativeTo aliasURL: URL) -> URL {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination, isDirectory: false)
                .standardizedFileURL
        }
        return aliasURL.deletingLastPathComponent()
            .appendingPathComponent(destination, isDirectory: false)
            .standardizedFileURL
    }
}
