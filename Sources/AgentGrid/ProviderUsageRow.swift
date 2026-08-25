import Foundation

enum ProviderUsageRowID: Hashable, Sendable {
    case window(ProviderUsageWindowID)
    case status(AgentKind)
}

struct ProviderUsageRow: Equatable, Identifiable, Sendable {
    let id: ProviderUsageRowID
    let provider: AgentKind
    let label: String
    let remainingPercent: Int?
    let valueText: String
    let resetText: String?
    let statusText: String?
    let isLoading: Bool
    let isUnavailable: Bool
    let isStale: Bool
    let helpText: String
    let accessibilityLabel: String
}

struct ProviderUsageWarning: Equatable, Sendable {
    let systemImage: String
    let accessibilityLabel: String
}

enum ProviderUsagePresentation {
    static func orderedSnapshots(
        _ snapshots: [ProviderUsageSnapshot]
    ) -> [ProviderUsageSnapshot] {
        CLIUsageService.displayedKinds.compactMap { provider in
            snapshots.first { $0.provider == provider }
        }
    }

    static func rows(
        for snapshot: ProviderUsageSnapshot,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [ProviderUsageRow] {
        let orderedWindows = snapshot.windows.sorted {
            windowSortKey($0) < windowSortKey($1)
        }
        guard !orderedWindows.isEmpty else {
            return [statusRow(for: snapshot)]
        }
        return orderedWindows.map { window in
            windowRow(
                window,
                provider: snapshot.provider,
                now: now,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    static func providerName(_ provider: AgentKind) -> String {
        switch provider {
        case .cursor: "Cursor"
        case .hermes: "Hermes"
        default: provider.displayName
        }
    }

    static func warning(for snapshot: ProviderUsageSnapshot) -> ProviderUsageWarning? {
        let provider = providerName(snapshot.provider)
        let state: String
        let reason: String
        switch snapshot.state {
        case .stale(let value):
            state = "stale"
            reason = value
        case .unavailable(let value):
            state = "unavailable"
            reason = value
        case .available:
            if let staleReason = snapshot.windows.lazy.compactMap({ window -> String? in
                if case .stale(let value, _) = window.freshness { return value }
                return nil
            }).first {
                state = "stale"
                reason = staleReason
            } else if snapshot.windows.isEmpty {
                state = "unavailable"
                reason = "Account quota is not exposed by this CLI."
            } else {
                return nil
            }
        case .loading:
            return nil
        }
        return ProviderUsageWarning(
            systemImage: "exclamationmark.triangle.fill",
            accessibilityLabel: "\(provider) usage is \(state). \(reason)"
        )
    }

    private static func statusRow(for snapshot: ProviderUsageSnapshot) -> ProviderUsageRow {
        let name = providerName(snapshot.provider)
        let valueText: String
        let helpText: String
        let isLoading: Bool
        let isUnavailable: Bool

        switch snapshot.state {
        case .loading:
            valueText = "Loading"
            helpText = "Refreshing \(name) account quota."
            isLoading = true
            isUnavailable = false
        case .unavailable(let reason), .stale(let reason):
            valueText = "Unavailable"
            helpText = reason
            isLoading = false
            isUnavailable = true
        case .available:
            valueText = "Unavailable"
            helpText = "Account quota is not exposed by this CLI."
            isLoading = false
            isUnavailable = true
        }

        return ProviderUsageRow(
            id: .status(snapshot.provider),
            provider: snapshot.provider,
            label: "Status",
            remainingPercent: nil,
            valueText: valueText,
            resetText: nil,
            statusText: nil,
            isLoading: isLoading,
            isUnavailable: isUnavailable,
            isStale: false,
            helpText: helpText,
            accessibilityLabel: "\(name), \(valueText.lowercased()), \(helpText)"
        )
    }

    private static func windowRow(
        _ window: ProviderUsageWindow,
        provider: AgentKind,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> ProviderUsageRow {
        let name = providerName(provider)
        let shortReset = window.resetsAt.map {
            shortDate($0, relativeTo: now, locale: locale, timeZone: timeZone)
        }
        let fullReset = window.resetsAt.map {
            fullDate($0, locale: locale, timeZone: timeZone)
        }
        let stale: (reason: String, lastSuccessfulAt: Date)?
        if case .stale(let reason, let lastSuccessfulAt) = window.freshness {
            stale = (reason, lastSuccessfulAt)
        } else {
            stale = nil
        }
        let statusText = stale.map { staleValue in
            let formatted = shortDate(
                staleValue.lastSuccessfulAt,
                relativeTo: now,
                locale: locale,
                timeZone: timeZone
            )
            return "Last updated \(formatted)"
        }

        var accessibilityParts = [
            name,
            window.label,
            "\(window.remainingPercent) percent remaining",
        ]
        if let fullReset {
            accessibilityParts.append("resets \(fullReset)")
        }
        if let stale {
            accessibilityParts.append("stale")
            let lastUpdated = fullDate(
                stale.lastSuccessfulAt,
                locale: locale,
                timeZone: timeZone
            )
            accessibilityParts.append("last updated \(lastUpdated)")
            accessibilityParts.append(stale.reason)
        }
        let accessibilityLabel = accessibilityParts.joined(separator: ", ")

        return ProviderUsageRow(
            id: .window(window.id),
            provider: provider,
            label: window.label,
            remainingPercent: window.remainingPercent,
            valueText: "\(window.remainingPercent)%",
            resetText: shortReset,
            statusText: statusText,
            isLoading: false,
            isUnavailable: false,
            isStale: stale != nil,
            helpText: accessibilityLabel,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func windowSortKey(_ window: ProviderUsageWindow) -> String {
        let priorities: [String: Int] = [
            "primary": 0,
            "five_hour": 0,
            "included": 0,
            "cursor_models": 0,
            "secondary": 1,
            "seven_day": 1,
            "on_demand": 1,
            "other_models": 1,
            "monthly": 2,
        ]
        let priority = priorities[window.id.key] ?? 10
        return String(format: "%03d.%@", priority, window.id.key)
    }

    private static func shortDate(
        _ date: Date,
        relativeTo now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let calendar = configuredCalendar(locale: locale, timeZone: timeZone)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, inSameDayAs: now) ? "jmm" : "EEEjmm"
        )
        return normalized(formatter.string(from: date))
    }

    private static func fullDate(
        _ date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return normalized(formatter.string(from: date))
    }

    private static func configuredCalendar(
        locale: Locale,
        timeZone: TimeZone
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
