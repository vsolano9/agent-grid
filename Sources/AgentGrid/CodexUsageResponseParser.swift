import Foundation

enum CLIUsageError: Error, Equatable {
    case invalidResponse
    case missingQuota
    case processEnded
    case timedOut
}

enum CodexUsageResponseParser {
    static func parse(_ value: String) throws -> Int {
        guard let data = value.data(using: .utf8),
              let response = try? JSONDecoder().decode(CodexRateLimitResponse.self, from: data) else {
            throw CLIUsageError.invalidResponse
        }
        guard let usedPercent = response.result?.rateLimits.primary?.usedPercent else {
            throw CLIUsageError.missingQuota
        }

        let boundedUsed = min(max(usedPercent, 0), 100)
        return 100 - boundedUsed
    }
}

private struct CodexRateLimitResponse: Decodable {
    struct Result: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercent: Int
            }

            let primary: Window?
        }

        let rateLimits: RateLimits
    }

    let result: Result?
}
