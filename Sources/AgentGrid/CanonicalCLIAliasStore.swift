import Darwin
import Foundation

actor CanonicalCLIAliasStore: CLIAliasMaintaining {
    private let homeDirectory: URL
    private let locator: CLIExecutableLocator
    private let fileManager = FileManager.default

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        locator = CLIExecutableLocator(
            homeDirectory: homeDirectory,
            environment: environment
        )
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

        guard let target = locator.locate(item.kind) else {
            throw CLIAliasError.noExecutable
        }
        guard target.standardizedFileURL != aliasURL else {
            throw CLIAliasError.selfReferentialTarget
        }

        try replaceAlias(at: aliasURL, with: target)
        return aliasURL
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
