import Foundation

actor GrokUsageReader: ProviderQuotaReading {
    static let defaultTimeout: Duration = .seconds(15)

    private let client: GrokACPUsageClient

    init(
        executable: URL,
        environment: [String: String],
        timeout: Duration = defaultTimeout
    ) {
        client = GrokACPUsageClient(
            executable: executable,
            environment: environment,
            timeout: timeout
        )
    }

    func fetchObservation() async throws -> ProviderUsageObservation {
        try await client.fetchObservation()
    }
}

enum GrokUsageParser {
    static func parseObservation(
        from data: Data,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageObservation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            throw GrokACPUsageError.invalidResponse
        }

        let currentPeriod = config["currentPeriod"] as? [String: Any]
        let periodType = currentPeriod?["type"] as? String
        let label = periodType?.contains("WEEKLY") == true ? "Weekly" : "Monthly"
        let resetValue: Any?
        if currentPeriod?.keys.contains("end") == true {
            resetValue = currentPeriod?["end"]
        } else {
            resetValue = config["billingPeriodEnd"]
        }
        let reset = ProviderUsageJSON.iso8601Date(resetValue)
        let resetIsMalformed = ProviderUsageJSON.hasMalformedDate(resetValue)
        var windows: [ProviderUsageWindowObservation] = []
        let includedID = ProviderUsageWindowID(provider: .grok, key: "included")

        if resetIsMalformed {
            windows.append(.failed(id: includedID, reason: "Grok included quota was malformed."))
        } else if let usedPercent = ProviderUsageJSON.number(config["creditUsagePercent"]) {
            windows.append(try available(
                key: "included",
                label: label,
                usedPercent: usedPercent,
                resetsAt: reset
            ))
        } else if let used = cents(config["used"]),
                  let limit = cents(config["monthlyLimit"]),
                  limit > 0 {
            windows.append(try available(
                key: "included",
                label: "Monthly",
                usedPercent: used / limit * 100,
                resetsAt: reset
            ))
        } else {
            windows.append(.failed(id: includedID, reason: "Grok included quota was malformed."))
        }

        let onDemandID = ProviderUsageWindowID(provider: .grok, key: "on_demand")
        if !root.keys.contains("onDemandEnabled") {
            windows.append(.failed(
                id: onDemandID,
                reason: "Grok on-demand availability was omitted."
            ))
        } else if root["onDemandEnabled"] is NSNull {
            windows.append(.removed(onDemandID))
        } else if root["onDemandEnabled"] as? Bool == true {
            if !resetIsMalformed,
               let used = cents(config["onDemandUsed"]),
               let cap = cents(config["onDemandCap"]),
               cap > 0 {
                windows.append(try available(
                    key: "on_demand",
                    label: "On demand",
                    usedPercent: used / cap * 100,
                    resetsAt: reset
                ))
            } else {
                windows.append(.failed(
                    id: onDemandID,
                    reason: "Grok on-demand quota was malformed."
                ))
            }
        } else if root["onDemandEnabled"] as? Bool == false {
            windows.append(.removed(onDemandID))
        } else {
            windows.append(.failed(
                id: onDemandID,
                reason: "Grok on-demand availability was malformed."
            ))
        }

        guard !windows.isEmpty else { throw ProviderUsageError.missingQuota }
        return ProviderUsageObservation(windows: windows, fetchedAt: fetchedAt)
    }

    private static func available(
        key: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date?
    ) throws -> ProviderUsageWindowObservation {
        .available(ProviderUsageWindowValue(
            id: ProviderUsageWindowID(provider: .grok, key: key),
            label: label,
            remainingPercent: try ProviderUsageMath.remainingPercent(usedPercent: usedPercent),
            resetsAt: resetsAt
        ))
    }

    private static func cents(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        return ProviderUsageJSON.number(object["val"])
    }
}
