import Foundation
import Testing
@testable import AgentGrid

@Suite("Provider usage presentation")
struct ProviderUsagePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_777_636_800) // 2026-05-01 12:00 UTC
    private let locale = Locale(identifier: "en_US_POSIX")
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    @Test("providers and semantic windows have deterministic stable ordering")
    func deterministicOrdering() throws {
        let snapshots = [
            snapshot(.cursor, windows: [window(.cursor, "monthly", "Monthly", 40)]),
            snapshot(.grok, windows: [
                window(.grok, "on_demand", "On-demand", 90),
                window(.grok, "included", "Weekly", 55),
            ]),
            snapshot(.codex, windows: [
                window(.codex, "secondary", "Weekly", 35),
                window(.codex, "primary", "5 hr", 75),
            ]),
            snapshot(.claude, windows: [
                window(.claude, "model.opus", "Opus", 20),
                window(.claude, "seven_day", "Weekly", 50),
                window(.claude, "five_hour", "5 hr", 80),
            ]),
        ]

        let ordered = ProviderUsagePresentation.orderedSnapshots(snapshots)
        let codexRows = ProviderUsagePresentation.rows(
            for: try #require(ordered.first),
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        let grokRows = ProviderUsagePresentation.rows(
            for: try #require(ordered.first { $0.provider == .grok }),
            now: now,
            locale: locale,
            timeZone: timeZone
        )

        #expect(ordered.map(\.provider) == [.codex, .claude, .grok, .cursor])
        #expect(codexRows.map(\.id) == [
            .window(ProviderUsageWindowID(provider: .codex, key: "primary")),
            .window(ProviderUsageWindowID(provider: .codex, key: "secondary")),
        ])
        #expect(grokRows.map(\.id) == [
            .window(ProviderUsageWindowID(provider: .grok, key: "included")),
            .window(ProviderUsageWindowID(provider: .grok, key: "on_demand")),
        ])
    }

    @Test("reset labels distinguish same-day and cross-day boundaries")
    func resetFormatting() throws {
        let sameDay = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 5 * 3_600 + 50 * 60)
        let nextDay = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 21 * 3_600)
        let value = snapshot(.codex, windows: [
            window(.codex, "primary", "5 hr", 75, resetsAt: sameDay),
            window(.codex, "secondary", "Weekly", 35, resetsAt: nextDay),
        ])

        let rows = ProviderUsagePresentation.rows(
            for: value,
            now: now,
            locale: locale,
            timeZone: timeZone
        )

        #expect(rows[0].resetText == "5:50 PM")
        #expect(rows[1].resetText == "Sat 9:00 AM")
    }

    @Test("reset labels honor a locale's 24-hour clock and localized weekday")
    func localizedResetFormatting() throws {
        let sameDay = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 5 * 3_600 + 50 * 60)
        let nextDay = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 21 * 3_600)
        let value = snapshot(.codex, windows: [
            window(.codex, "primary", "5 hr", 75, resetsAt: sameDay),
            window(.codex, "secondary", "Weekly", 35, resetsAt: nextDay),
        ])

        let rows = ProviderUsagePresentation.rows(
            for: value,
            now: now,
            locale: Locale(identifier: "de_DE"),
            timeZone: timeZone
        )

        #expect(rows[0].resetText == "17:50")
        #expect(rows[1].resetText == "Sa. 09:00")
    }

    @Test("stale rows expose last-updated text and sanitized reason")
    func staleMetadata() throws {
        let lastGood = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 30 * 60)
        let reason = "Codex quota refresh timed out."
        let value = ProviderUsageSnapshot(
            provider: .codex,
            state: .stale(reason: reason),
            windows: [window(
                .codex,
                "primary",
                "5 hr",
                75,
                freshness: .stale(reason: reason, lastSuccessfulAt: lastGood),
                lastSuccessfulAt: lastGood
            )],
            fetchedAt: lastGood
        )

        let row = try #require(ProviderUsagePresentation.rows(
            for: value,
            now: now,
            locale: locale,
            timeZone: timeZone
        ).first)

        #expect(row.isStale)
        #expect(row.statusText == "Last updated 11:30 AM")
        #expect(row.helpText.contains(reason))
    }

    @Test("loading and unavailable providers have explicit visible rows")
    func providerStates() throws {
        let loading = ProviderUsageSnapshot(
            provider: .claude,
            state: .loading,
            windows: [],
            fetchedAt: nil
        )
        let unavailable = ProviderUsageSnapshot(
            provider: .cursor,
            state: .unavailable(reason: "Cursor credentials are unavailable."),
            windows: [],
            fetchedAt: nil
        )

        let loadingRow = try #require(ProviderUsagePresentation.rows(
            for: loading, now: now, locale: locale, timeZone: timeZone
        ).first)
        let unavailableRow = try #require(ProviderUsagePresentation.rows(
            for: unavailable, now: now, locale: locale, timeZone: timeZone
        ).first)

        #expect(loadingRow.id == .status(.claude))
        #expect(loadingRow.valueText == "Loading")
        #expect(unavailableRow.id == .status(.cursor))
        #expect(unavailableRow.valueText == "Unavailable")
        #expect(unavailableRow.helpText == "Cursor credentials are unavailable.")
    }

    @Test("stale and unavailable providers expose an explicit accessible warning marker")
    func providerWarningMarkers() throws {
        let staleReason = "Codex quota refresh timed out."
        let unavailableReason = "Cursor credentials are unavailable."
        let stale = ProviderUsageSnapshot(
            provider: .codex,
            state: .stale(reason: staleReason),
            windows: [window(.codex, "primary", "5 hr", 75)],
            fetchedAt: now
        )
        let unavailable = ProviderUsageSnapshot(
            provider: .cursor,
            state: .unavailable(reason: unavailableReason),
            windows: [],
            fetchedAt: nil
        )
        let partialReason = "Codex secondary quota was malformed."
        let mixed = ProviderUsageSnapshot(
            provider: .codex,
            state: .available,
            windows: [
                window(.codex, "primary", "5 hr", 75),
                window(
                    .codex,
                    "secondary",
                    "Weekly",
                    35,
                    freshness: .stale(reason: partialReason, lastSuccessfulAt: now)
                ),
            ],
            fetchedAt: now
        )

        let staleWarning = try #require(ProviderUsagePresentation.warning(for: stale))
        let unavailableWarning = try #require(ProviderUsagePresentation.warning(for: unavailable))
        let mixedWarning = try #require(ProviderUsagePresentation.warning(for: mixed))

        #expect(staleWarning.systemImage == "exclamationmark.triangle.fill")
        #expect(staleWarning.accessibilityLabel == "Codex usage is stale. \(staleReason)")
        #expect(unavailableWarning.systemImage == "exclamationmark.triangle.fill")
        #expect(unavailableWarning.accessibilityLabel == "Cursor usage is unavailable. \(unavailableReason)")
        #expect(mixedWarning.systemImage == "exclamationmark.triangle.fill")
        #expect(mixedWarning.accessibilityLabel == "Codex usage is stale. \(partialReason)")
        let emptyWarning = try #require(ProviderUsagePresentation.warning(
            for: snapshot(.grok, windows: [])
        ))
        #expect(emptyWarning.systemImage == "exclamationmark.triangle.fill")
        #expect(emptyWarning.accessibilityLabel == "Grok usage is unavailable. Account quota is not exposed by this CLI.")
    }

    @Test("accessibility labels include provider, window, percentage, reset, and freshness")
    func completeAccessibilityLabel() throws {
        let reset = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 5 * 3_600 + 50 * 60)
        let lastGood = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 30 * 60)
        let reason = "Grok billing refresh timed out."
        let value = ProviderUsageSnapshot(
            provider: .grok,
            state: .stale(reason: reason),
            windows: [window(
                .grok,
                "included",
                "Weekly",
                42,
                resetsAt: reset,
                freshness: .stale(reason: reason, lastSuccessfulAt: lastGood),
                lastSuccessfulAt: lastGood
            )],
            fetchedAt: lastGood
        )

        let row = try #require(ProviderUsagePresentation.rows(
            for: value,
            now: now,
            locale: locale,
            timeZone: timeZone
        ).first)

        #expect(row.accessibilityLabel == "Grok, Weekly, 42 percent remaining, resets May 1, 2026 at 5:50 PM, stale, last updated May 1, 2026 at 11:30 AM, Grok billing refresh timed out.")
    }
}

private func snapshot(
    _ provider: AgentKind,
    windows: [ProviderUsageWindow]
) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(
        provider: provider,
        state: .available,
        windows: windows,
        fetchedAt: windows.map(\.lastSuccessfulAt).max()
    )
}

private func window(
    _ provider: AgentKind,
    _ key: String,
    _ label: String,
    _ remainingPercent: Int,
    resetsAt: Date? = nil,
    freshness: ProviderUsageFreshness = .fresh,
    lastSuccessfulAt: Date = Date(timeIntervalSince1970: 1_777_636_800)
) -> ProviderUsageWindow {
    ProviderUsageWindow(
        value: ProviderUsageWindowValue(
            id: ProviderUsageWindowID(provider: provider, key: key),
            label: label,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt
        ),
        freshness: freshness,
        lastSuccessfulAt: lastSuccessfulAt
    )
}
