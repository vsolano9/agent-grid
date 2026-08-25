import CoreFoundation
import Foundation

struct ProviderUsageHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol ProviderUsageHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse
}

actor URLSessionProviderUsageHTTPTransport: ProviderUsageHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled
                || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderUsageError.invalidResponse
        }
        return ProviderUsageHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

protocol ProviderAccessTokenLoading: Sendable {
    func loadAccessToken() async throws -> String
}

enum ProviderUsageError: Error, Equatable {
    case missingCredentials
    case authenticationRequired
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

enum ProviderUsageJSON {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func iso8601Date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    static func hasMalformedDate(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return iso8601Date(value) == nil
    }

    static func hasMalformedNumber(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return number(value) == nil
    }
}
