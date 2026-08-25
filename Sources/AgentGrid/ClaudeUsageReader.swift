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

    func fetchObservation() async throws -> ProviderUsageObservation {
        let token = try await accessTokenLoader.loadAccessToken()
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProviderUsageError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let response = try await transport.response(for: request)
        guard response.statusCode != 401 else {
            throw ProviderUsageError.authenticationRequired
        }
        guard response.statusCode == 200 else {
            throw ProviderUsageError.httpStatus(response.statusCode)
        }
        return try ClaudeUsageParser.parseObservation(from: response.data)
    }
}

struct ClaudeAccessTokenStore: ProviderAccessTokenLoading {
    static let protectedResource = "Claude credentials"

    let environment: [String: String]
    let homeDirectory: URL
    private let fileDataLoader: @Sendable (URL) throws -> Data
    private let fallbackAccessTokenLoader: @Sendable () throws -> String
    private let permissionReporter: (any ProtectedFileAccessReporting)?

    init(
        environment: [String: String],
        homeDirectory: URL,
        fileDataLoader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0)
        },
        fallbackAccessTokenLoader: @escaping @Sendable () throws -> String = {
            try Self.loadKeychainAccessToken()
        },
        permissionReporter: (any ProtectedFileAccessReporting)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileDataLoader = fileDataLoader
        self.fallbackAccessTokenLoader = fallbackAccessTokenLoader
        self.permissionReporter = permissionReporter
    }

    func loadAccessToken() async throws -> String {
        let configDirectory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
            ?? environment["CLAUDE_CONFIG_DIR"]
        let base = configDirectory.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let file = base.appendingPathComponent(".credentials.json")
        var fileCredentialError: ProviderUsageError?
        do {
            let data = try fileDataLoader(file)
            await permissionReporter?.fileOperationSucceeded(resource: Self.protectedResource)
            do {
                return try ClaudeCredentialParser.accessToken(from: data)
            } catch let error as ProviderUsageError {
                fileCredentialError = error
            }
        } catch {
            await permissionReporter?.fileOperationFailed(error, resource: Self.protectedResource)
        }

        do {
            return try fallbackAccessTokenLoader()
        } catch {
            if fileCredentialError == .authenticationRequired {
                throw ProviderUsageError.authenticationRequired
            }
            throw error
        }
    }

    private static func loadKeychainAccessToken() throws -> String {
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
    static func accessToken(from data: Data, now: Date = Date()) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw ProviderUsageError.missingCredentials
        }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProviderUsageError.missingCredentials }
        if let rawExpiresAt = oauth["expiresAt"], !(rawExpiresAt is NSNull) {
            guard let expiresAt = ProviderUsageJSON.number(rawExpiresAt),
                  expiresAt.isFinite,
                  expiresAt > now.timeIntervalSince1970 * 1_000 else {
                throw ProviderUsageError.authenticationRequired
            }
        }
        return normalized
    }
}

enum ClaudeUsageParser {
    static func parseObservation(
        from data: Data,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageObservation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        let accountKeys = ["five_hour", "seven_day"]
        let namedKeys = root.keys.filter {
            !accountKeys.contains($0) && $0 != "extra_usage" && $0 != "limits"
        }.sorted()
        var observations: [ProviderUsageWindowObservation] = []
        for key in accountKeys + namedKeys {
            let id = ProviderUsageWindowID(provider: .claude, key: key)
            guard let raw = root[key] else {
                observations.append(.failed(id: id, reason: "Claude \(key) quota was missing."))
                continue
            }
            if raw is NSNull {
                observations.append(.removed(id))
                continue
            }
            guard let window = raw as? [String: Any],
                  let utilization = ProviderUsageJSON.number(window["utilization"]),
                  utilization.isFinite,
                  !ProviderUsageJSON.hasMalformedDate(window["resets_at"]) else {
                observations.append(.failed(
                    id: id,
                    reason: "Claude \(key) quota was malformed."
                ))
                continue
            }
            observations.append(.available(ProviderUsageWindowValue(
                id: id,
                label: label(for: key),
                remainingPercent: try ProviderUsageMath.remainingPercent(usedPercent: utilization),
                resetsAt: ProviderUsageJSON.iso8601Date(window["resets_at"])
            )))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                let id = ProviderUsageWindowID(provider: .claude, key: "limit.\(name)")
                guard entry["is_active"] as? Bool != false else {
                    observations.append(.removed(id))
                    continue
                }
                guard let percent = ProviderUsageJSON.number(entry["percent"]),
                      percent.isFinite,
                      !ProviderUsageJSON.hasMalformedDate(entry["resets_at"]) else {
                    observations.append(.failed(
                        id: id,
                        reason: "Claude \(name) quota was malformed."
                    ))
                    continue
                }
                observations.append(.available(ProviderUsageWindowValue(
                    id: id,
                    label: label(for: name),
                    remainingPercent: try ProviderUsageMath.remainingPercent(usedPercent: percent),
                    resetsAt: ProviderUsageJSON.iso8601Date(entry["resets_at"])
                )))
            }
        }
        guard !observations.isEmpty else { throw ProviderUsageError.missingQuota }
        return ProviderUsageObservation(windows: observations, fetchedAt: fetchedAt)
    }

    private static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5 hr"
        case "seven_day": return "Weekly"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
