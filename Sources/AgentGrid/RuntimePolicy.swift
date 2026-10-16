import Foundation

struct WorkspaceLocator: Sendable {
    private let homeDirectory: URL
    private let isDirectory: @Sendable (URL) -> Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isDirectory: @escaping @Sendable (URL) -> Bool = { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    ) {
        self.homeDirectory = homeDirectory
        self.isDirectory = isDirectory
    }

    /// The saved default folder while it still exists, otherwise the user's home directory.
    func workspace(preferring savedDefault: URL? = nil) -> URL {
        if let savedDefault, isDirectory(savedDefault) {
            return savedDefault
        }
        return homeDirectory
    }
}

enum TerminalEnvironment {
    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        let existingPath = (base["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbacks = fallbackDirectories(homeDirectory: homeDirectory).map(\.path)
        let canonicalAliasDirectory = homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .path

        environment["PATH"] = unique(
            [canonicalAliasDirectory] + existingPath + fallbacks
        ).joined(separator: ":")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment
    }

    static func fallbackDirectories(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".grok/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".cursor/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ]
    }

    static func processVariables(_ environment: [String: String]) -> [String] {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
