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

    func fetchRemainingPercent() async throws -> Int {
        let token = try accessTokenLoader.loadAccessToken()
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
        return try CursorUsageParser.remainingPercent(from: response.data)
    }
}

struct CursorAccessTokenStore: ProviderAccessTokenLoading {
    let environment: [String: String]
    let homeDirectory: URL

    func loadAccessToken() throws -> String {
        let database: URL
        if let custom = environment["CURSOR_USER_DATA_DIR"], !custom.isEmpty {
            database = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
                .appendingPathComponent("User/globalStorage/state.vscdb")
        } else {
            database = homeDirectory
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(database.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close(handle) }
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
    static func remainingPercent(from data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]

        let usedPercent: Double?
        if let total = number(plan?["totalPercentUsed"]) {
            usedPercent = total
        } else if let auto = number(plan?["autoPercentUsed"]),
                  let api = number(plan?["apiPercentUsed"]) {
            usedPercent = (auto + api) / 2
        } else if let api = number(plan?["apiPercentUsed"]) {
            usedPercent = api
        } else if let auto = number(plan?["autoPercentUsed"]) {
            usedPercent = auto
        } else {
            usedPercent = ratio(in: plan) ?? ratio(in: overall) ?? ratio(in: pooled)
        }
        guard let usedPercent else { throw ProviderUsageError.missingQuota }
        return try ProviderUsageMath.remainingPercent(usedPercent: usedPercent)
    }

    private static func ratio(in value: [String: Any]?) -> Double? {
        guard let used = number(value?["used"]),
              let limit = number(value?["limit"]), limit > 0 else { return nil }
        return used / limit * 100
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
