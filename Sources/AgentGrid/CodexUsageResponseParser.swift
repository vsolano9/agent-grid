import Foundation

enum CLIUsageError: Error, Equatable {
    case invalidResponse
    case missingQuota
    case processEnded
    case timedOut
}

enum CodexUsageResponseParser {
    static func parseObservation(
        _ value: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageObservation {
        guard let data = value.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else {
            throw CLIUsageError.invalidResponse
        }

        var windows: [ProviderUsageWindowObservation] = []
        for key in ["primary", "secondary"] {
            let id = ProviderUsageWindowID(provider: .codex, key: key)
            guard let raw = limits[key] else {
                windows.append(.failed(id: id, reason: "Codex \(key) quota was missing."))
                continue
            }
            if raw is NSNull {
                windows.append(.removed(id))
                continue
            }
            guard let window = raw as? [String: Any] else {
                windows.append(.failed(id: id, reason: "Codex \(key) quota was malformed."))
                continue
            }
            let durationValue = window["windowDurationMins"]
            let duration = durationValue.flatMap(validDurationMinutes)
            let durationIsMalformed = durationValue != nil && duration == nil
            guard let used = ProviderUsageJSON.number(window["usedPercent"]),
                  used.isFinite,
                  !durationIsMalformed,
                  !ProviderUsageJSON.hasMalformedNumber(window["resetsAt"]) else {
                windows.append(.failed(id: id, reason: "Codex \(key) quota was malformed."))
                continue
            }
            windows.append(.available(ProviderUsageWindowValue(
                id: id,
                label: label(for: key, durationMinutes: duration),
                remainingPercent: try ProviderUsageMath.remainingPercent(usedPercent: used),
                resetsAt: ProviderUsageJSON.number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            )))
        }
        guard !windows.isEmpty else { throw CLIUsageError.missingQuota }
        return ProviderUsageObservation(windows: windows, fetchedAt: fetchedAt)
    }

    private static func validDurationMinutes(_ value: Any) -> Int? {
        guard let number = ProviderUsageJSON.number(value),
              number.isFinite,
              let duration = Int(exactly: number),
              duration > 0 else {
            return nil
        }
        return duration
    }

    private static func label(for key: String, durationMinutes: Int?) -> String {
        guard let durationMinutes else { return key.capitalized }
        switch durationMinutes {
        case 300: return "5 hr"
        case 10_080: return "Weekly"
        case let minutes where minutes % 1_440 == 0: return "\(minutes / 1_440) day"
        case let minutes where minutes % 60 == 0: return "\(minutes / 60) hr"
        default: return "\(durationMinutes) min"
        }
    }

}
