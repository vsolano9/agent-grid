import Foundation

struct BinaryResolver: ExecutableResolving {
    private let searchDirectories: [URL]
    private let isExecutable: @Sendable (String) -> Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let fallbackDirectories = TerminalEnvironment.fallbackDirectories(homeDirectory: homeDirectory)

        searchDirectories = Self.unique(pathDirectories + fallbackDirectories)
        self.isExecutable = isExecutable
    }

    func resolve(_ executableName: String) -> URL? {
        searchDirectories
            .map { $0.appendingPathComponent(executableName, isDirectory: false) }
            .first { isExecutable($0.path) }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
