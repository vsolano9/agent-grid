import Darwin
import Foundation

actor CanonicalCLIAliasStore: CLIAliasMaintaining {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let fileManager = FileManager.default

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
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

        if let destination = symbolicLinkDestination(at: aliasURL) {
            let resolvedDestination = resolved(destination, relativeTo: aliasURL)
            guard resolvedDestination.standardizedFileURL != aliasURL else {
                throw CLIAliasError.selfReferentialTarget
            }

            if fileManager.isExecutableFile(atPath: resolvedDestination.path) {
                try replaceAlias(at: aliasURL, with: resolvedDestination)
                return aliasURL
            }
        } else if fileManager.fileExists(atPath: aliasURL.path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: aliasURL.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                throw CLIAliasError.destinationIsDirectory
            }
            if fileManager.isExecutableFile(atPath: aliasURL.path) {
                return aliasURL
            }
        }

        guard let target = executableTarget(
            named: item.kind.executableName,
            excluding: canonicalDirectory
        ) else {
            throw CLIAliasError.noExecutable
        }
        guard target.standardizedFileURL != aliasURL else {
            throw CLIAliasError.selfReferentialTarget
        }

        try replaceAlias(at: aliasURL, with: target)
        return aliasURL
    }

    private func executableTarget(named name: String, excluding aliasDirectory: URL) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let candidates = pathDirectories
            + TerminalEnvironment.fallbackDirectories(homeDirectory: homeDirectory)

        var seen = Set<String>()
        for directory in candidates {
            let standardizedDirectory = directory.standardizedFileURL
            guard standardizedDirectory != aliasDirectory,
                  seen.insert(standardizedDirectory.path).inserted else {
                continue
            }

            let candidate = standardizedDirectory
                .appendingPathComponent(name, isDirectory: false)
                .resolvingSymlinksInPath()
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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

    private func symbolicLinkDestination(at url: URL) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    private func resolved(_ destination: String, relativeTo aliasURL: URL) -> URL {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination, isDirectory: false)
                .resolvingSymlinksInPath()
        }
        return aliasURL.deletingLastPathComponent()
            .appendingPathComponent(destination, isDirectory: false)
            .resolvingSymlinksInPath()
    }
}
