import Foundation
import Testing
@testable import AgentGrid

struct ProviderUsageReaderTests {
    @Test("Claude uses the most constrained active quota window")
    func claudeUsesMostConstrainedWindow() throws {
        let payload = Data(#"""
        {
          "five_hour":{"utilization":2.2},
          "seven_day":{"utilization":74.6},
          "seven_day_opus":{"utilization":19},
          "limits":[{"percent":81.2,"is_active":true},{"percent":99,"is_active":false}]
        }
        """#.utf8)

        #expect(try ClaudeUsageParser.remainingPercent(from: payload) == 19)
    }

    @Test("Claude credential parser extracts the OAuth access token")
    func claudeCredentialParser() throws {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"claude-test-token","expiresAt":9999999999999}}"#.utf8)

        #expect(try ClaudeCredentialParser.accessToken(from: payload) == "claude-test-token")
    }

    @Test("Claude reader sends the required OAuth headers")
    func claudeRequest() async throws {
        let transport = RecordingHTTPTransport(
            data: Data(#"{"five_hour":{"utilization":12}}"#.utf8)
        )
        let reader = ClaudeUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: "claude-test-token"),
            transport: transport
        )

        #expect(try await reader.fetchRemainingPercent() == 88)
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test("Grok auth parser prefers the OIDC bearer token")
    func grokAuthPrefersOIDC() throws {
        let payload = Data(#"""
        {
          "https://grok.com/sign-in":{"key":"legacy-token"},
          "https://accounts.x.ai/.well-known/openid-configuration":{"key":"oidc-token"}
        }
        """#.utf8)

        #expect(try GrokAuthTokenParser.accessToken(from: payload) == "oidc-token")
    }

    @Test("Grok reader sends CLI auth and converts credit usage")
    func grokRequest() async throws {
        let transport = RecordingHTTPTransport(
            data: Data(#"{"config":{"creditUsagePercent":4.4}}"#.utf8)
        )
        let reader = GrokUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: "grok-test-token"),
            transport: transport
        )

        #expect(try await reader.fetchRemainingPercent() == 96)
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-test-token")
        #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
    }

    @Test("Grok falls back to used and cap amounts")
    func grokAmountFallback() throws {
        let payload = Data(#"{"config":{"onDemandUsed":{"val":25},"onDemandCap":{"val":80}}}"#.utf8)

        #expect(try GrokUsageParser.remainingPercent(from: payload) == 69)
    }

    @Test("Cursor builds the authenticated cookie from its JWT subject")
    func cursorCookie() throws {
        let token = makeJWT(payload: #"{"sub":"auth0|user_123"}"#)

        #expect(try CursorAuthTokenParser.cookieHeader(accessToken: token) ==
            "WorkosCursorSessionToken=user_123%3A%3A\(token)")
    }

    @Test("Cursor usage parser follows total-percent and ratio precedence")
    func cursorUsagePrecedence() throws {
        let total = Data(#"{"individualUsage":{"plan":{"totalPercentUsed":17.3214,"used":99,"limit":100}}}"#.utf8)
        let overall = Data(#"{"individualUsage":{"overall":{"used":30,"limit":80}}}"#.utf8)

        #expect(try CursorUsageParser.remainingPercent(from: total) == 83)
        #expect(try CursorUsageParser.remainingPercent(from: overall) == 63)
    }

    @Test("Cursor reader sends its local app session cookie")
    func cursorRequest() async throws {
        let token = makeJWT(payload: #"{"sub":"workos|cursor-user"}"#)
        let transport = RecordingHTTPTransport(
            data: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8)
        )
        let reader = CursorUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: token),
            transport: transport
        )

        #expect(try await reader.fetchRemainingPercent() == 80)
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "https://cursor.com/api/usage-summary")
        #expect(request.value(forHTTPHeaderField: "Cookie") ==
            "WorkosCursorSessionToken=cursor-user%3A%3A\(token)")
    }

    @Test("Provider readers reject non-success HTTP responses")
    func providerRejectsHTTPError() async {
        let reader = GrokUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: "grok-test-token"),
            transport: RecordingHTTPTransport(data: Data(), statusCode: 401)
        )

        await #expect(throws: ProviderUsageError.httpStatus(401)) {
            try await reader.fetchRemainingPercent()
        }
    }

    private func makeJWT(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

private struct StaticAccessTokenLoader: ProviderAccessTokenLoading {
    let token: String

    func loadAccessToken() throws -> String { token }
}

private actor RecordingHTTPTransport: ProviderUsageHTTPTransport {
    let data: Data
    let statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse {
        lastRequest = request
        return ProviderUsageHTTPResponse(data: data, statusCode: statusCode)
    }
}
