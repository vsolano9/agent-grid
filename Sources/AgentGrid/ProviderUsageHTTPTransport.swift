import Foundation

struct ProviderUsageHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol ProviderUsageHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse
}

actor URLSessionProviderUsageHTTPTransport: ProviderUsageHTTPTransport {
    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderUsageError.invalidResponse
        }
        return ProviderUsageHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

protocol ProviderAccessTokenLoading: Sendable {
    func loadAccessToken() throws -> String
}

enum ProviderUsageError: Error, Equatable {
    case missingCredentials
    case invalidResponse
    case missingQuota
    case httpStatus(Int)
    case database(Int32)
}

enum ProviderUsageMath {
    static func remainingPercent(usedPercent: Double) throws -> Int {
        guard usedPercent.isFinite else { throw ProviderUsageError.invalidResponse }
        let bounded = min(max(usedPercent, 0), 100)
        return Int((100 - bounded).rounded())
    }
}
