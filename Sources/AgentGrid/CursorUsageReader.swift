import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor CursorUsageReader: ProviderQuotaReading {
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
        let cookie = try CursorAuthTokenParser.cookieHeader(accessToken: token)
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw ProviderUsageError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw ProviderUsageError.httpStatus(response.statusCode)
        }
        return try CursorUsageParser.parseObservation(from: response.data)
    }
}

struct CursorAccessTokenStore: ProviderAccessTokenLoading {
    static let protectedResource = "Cursor credentials"

    let environment: [String: String]
    let homeDirectory: URL
    private let databaseAccessTokenLoader: @Sendable (URL) throws -> String
    private let permissionReporter: (any ProtectedFileAccessReporting)?

    init(
        environment: [String: String],
        homeDirectory: URL,
        databaseAccessTokenLoader: @escaping @Sendable (URL) throws -> String = {
            try Self.readAccessToken(from: $0)
        },
        permissionReporter: (any ProtectedFileAccessReporting)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.databaseAccessTokenLoader = databaseAccessTokenLoader
        self.permissionReporter = permissionReporter
    }

    func loadAccessToken() async throws -> String {
        let database: URL
        if let custom = environment["CURSOR_USER_DATA_DIR"], !custom.isEmpty {
            database = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("User/globalStorage/state.vscdb")
        } else {
            database = homeDirectory
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }

        do {
            let token = try databaseAccessTokenLoader(database)
            await permissionReporter?.fileOperationSucceeded(resource: Self.protectedResource)
            return token
        } catch {
            await permissionReporter?.fileOperationFailed(error, resource: Self.protectedResource)
            throw error
        }
    }

    private static func readAccessToken(from database: URL) throws -> String {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(database.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let systemError = handle.map(sqlite3_system_errno) ?? 0
            if handle != nil { sqlite3_close(handle) }
            if systemError == EACCES || systemError == EPERM {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(systemError))
            }
            throw ProviderUsageError.database(openResult)
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw ProviderUsageError.database(sqlite3_errcode(handle))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else {
            throw ProviderUsageError.missingCredentials
        }
        let token = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderUsageError.missingCredentials }
        return token
    }
}

enum CursorAuthTokenParser {
    static func cookieHeader(accessToken: String) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw ProviderUsageError.missingCredentials }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last,
              !userID.isEmpty else {
            throw ProviderUsageError.missingCredentials
        }
        let value = String(userID)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProviderUsageError.invalidResponse
        }
        return "WorkosCursorSessionToken=\(value)%3A%3A\(accessToken)"
    }
}

enum CursorUsageParser {
    static func parseObservation(
        from data: Data,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageObservation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]

        let resetValue = root["billingCycleEnd"]
        let reset = ProviderUsageJSON.iso8601Date(resetValue)
        let resetIsMalformed = ProviderUsageJSON.hasMalformedDate(resetValue)
        var observations: [ProviderUsageWindowObservation] = []
        let usesPoolWindows = plan?.keys.contains("autoPercentUsed") == true
            || plan?.keys.contains("apiPercentUsed") == true
        if usesPoolWindows {
            observations.append(.removed(ProviderUsageWindowID(provider: .cursor, key: "monthly")))
            for (field, key, label) in [
                ("autoPercentUsed", "cursor_models", "Cursor Models"),
                ("apiPercentUsed", "other_models", "Other Models"),
            ] {
                let id = ProviderUsageWindowID(provider: .cursor, key: key)
                guard let raw = plan?[field] else {
                    observations.append(.failed(
                        id: id,
                        reason: "Cursor \(label.lowercased()) quota was missing."
                    ))
                    continue
                }
                if raw is NSNull {
                    observations.append(.removed(id))
                    continue
                }
                guard let percent = ProviderUsageJSON.number(raw),
                      percent.isFinite,
                      !resetIsMalformed else {
                    observations.append(.failed(
                        id: id,
                        reason: "Cursor \(label.lowercased()) quota was malformed."
                    ))
                    continue
                }
                observations.append(try available(
                    key: key,
                    label: label,
                    usedPercent: percent,
                    resetsAt: reset
                ))
            }
        } else {
            let pooledIsApplicable = pooled?["enabled"] as? Bool == true
            let composite = ProviderUsageJSON.number(plan?["totalPercentUsed"])
                ?? ratio(in: plan)
                ?? ratio(in: overall)
                ?? (pooledIsApplicable ? ratio(in: pooled) : nil)
            guard let composite, composite.isFinite else {
                throw ProviderUsageError.missingQuota
            }
            observations.append(.removed(ProviderUsageWindowID(provider: .cursor, key: "cursor_models")))
            observations.append(.removed(ProviderUsageWindowID(provider: .cursor, key: "other_models")))
            let monthlyID = ProviderUsageWindowID(provider: .cursor, key: "monthly")
            if resetIsMalformed {
                observations.append(.failed(
                    id: monthlyID,
                    reason: "Cursor monthly quota was malformed."
                ))
            } else {
                observations.append(try available(
                    key: "monthly",
                    label: "Monthly",
                    usedPercent: composite,
                    resetsAt: reset
                ))
            }
        }
        return ProviderUsageObservation(windows: observations, fetchedAt: fetchedAt)
    }

    private static func available(
        key: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date?
    ) throws -> ProviderUsageWindowObservation {
        .available(ProviderUsageWindowValue(
            id: ProviderUsageWindowID(provider: .cursor, key: key),
            label: label,
            remainingPercent: try ProviderUsageMath.remainingPercent(usedPercent: usedPercent),
            resetsAt: resetsAt
        ))
    }

    private static func ratio(in value: [String: Any]?) -> Double? {
        guard let used = ProviderUsageJSON.number(value?["used"]),
              let limit = ProviderUsageJSON.number(value?["limit"]), limit > 0 else { return nil }
        return used / limit * 100
    }
}
