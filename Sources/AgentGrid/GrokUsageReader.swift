import Foundation

actor GrokUsageReader: ProviderQuotaReading {
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
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            throw ProviderUsageError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw ProviderUsageError.httpStatus(response.statusCode)
        }
        return try GrokUsageParser.remainingPercent(from: response.data)
    }
}

struct GrokAccessTokenStore: ProviderAccessTokenLoading {
    let environment: [String: String]
    let homeDirectory: URL

    func loadAccessToken() throws -> String {
        let directory = environment["GROK_HOME"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".grok", isDirectory: true)
        return try GrokAuthTokenParser.accessToken(
            from: Data(contentsOf: directory.appendingPathComponent("auth.json"))
        )
    }
}

enum GrokAuthTokenParser {
    static func accessToken(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.missingCredentials
        }
        let entries = root.compactMap { key, value -> (String, String)? in
            guard let item = value as? [String: Any],
                  let token = item["key"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (key, token)
        }
        let preferred = entries.first { key, _ in
            key.hasPrefix("https://auth.x.ai::") || key.contains("openid-configuration")
        }
        let legacy = entries.first { key, _ in
            key == "https://accounts.x.ai/sign-in" || key.contains("/sign-in")
        }
        guard let token = (preferred ?? legacy)?.1 else {
            throw ProviderUsageError.missingCredentials
        }
        return token
    }
}

enum GrokUsageParser {
    static func remainingPercent(from data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        if let usedPercent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue {
            return try ProviderUsageMath.remainingPercent(usedPercent: usedPercent)
        }
        guard let used = ((config["onDemandUsed"] as? [String: Any])?["val"] as? NSNumber)?.doubleValue,
              let cap = ((config["onDemandCap"] as? [String: Any])?["val"] as? NSNumber)?.doubleValue,
              cap > 0 else {
            throw ProviderUsageError.missingQuota
        }
        return try ProviderUsageMath.remainingPercent(usedPercent: used / cap * 100)
    }
}
