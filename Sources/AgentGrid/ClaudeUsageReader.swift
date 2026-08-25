import Foundation

actor ClaudeUsageReader: ProviderQuotaReading {
    private let accessTokenLoader: any ProviderAccessTokenLoading
    private let transport: any ProviderUsageHTTPTransport

    init(
        accessTokenLoader: any ProviderAccessTokenLoading,
        transport: any ProviderUsageHTTPTransport
    ) {
        self.accessTokenLoader = accessTokenLoader
        self.transport = transport
    }

    func fetchRemainingPercent() async throws -> Int {
        let token = try accessTokenLoader.loadAccessToken()
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProviderUsageError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw ProviderUsageError.httpStatus(response.statusCode)
        }
        return try ClaudeUsageParser.remainingPercent(from: response.data)
    }
}

struct ClaudeAccessTokenStore: ProviderAccessTokenLoading {
    let environment: [String: String]
    let homeDirectory: URL

    func loadAccessToken() throws -> String {
        let configDirectory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
            ?? environment["CLAUDE_CONFIG_DIR"]
        let base = configDirectory.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let file = base.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file),
           let token = try? ClaudeCredentialParser.accessToken(from: data) {
            return token
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ProviderUsageError.missingCredentials
        }
        guard process.terminationStatus == 0 else {
            throw ProviderUsageError.missingCredentials
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try ClaudeCredentialParser.accessToken(from: data)
    }
}

enum ClaudeCredentialParser {
    static func accessToken(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw ProviderUsageError.missingCredentials
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProviderUsageError.missingCredentials }
        return normalized
    }
}

enum ClaudeUsageParser {
    static func remainingPercent(from data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        var usedValues: [Double] = []
        for (key, value) in root where key != "extra_usage" {
            guard let window = value as? [String: Any],
                  let utilization = number(window["utilization"]) else { continue }
            usedValues.append(utilization)
        }
        if let limits = root["limits"] as? [[String: Any]] {
            usedValues += limits.compactMap { entry in
                guard entry["is_active"] as? Bool != false else { return nil }
                return number(entry["percent"])
            }
        }
        guard let used = usedValues.max() else { throw ProviderUsageError.missingQuota }
        return try ProviderUsageMath.remainingPercent(usedPercent: used)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
