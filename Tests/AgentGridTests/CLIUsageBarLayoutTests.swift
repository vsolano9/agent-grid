import AppKit
import SwiftUI
import Testing
@testable import AgentGrid

@MainActor
struct CLIUsageBarLayoutTests {
    @Test(
        "quota footer remains a compact status strip in every data state",
        arguments: FooterFixture.allCases,
        [CGFloat(800), CGFloat(1_280), CGFloat(2_048)]
    )
    func compactFooterHeight(fixture: FooterFixture, width: CGFloat) {
        let view = CLIUsageBar(
            snapshots: fixture.snapshots,
            isRefreshing: fixture == .refreshing,
            refresh: {}
        )
        .frame(width: width)
        let hostingView = NSHostingView(rootView: view)

        let height = hostingView.fittingSize.height

        #expect(height >= 28, "\(fixture) footer was only \(height) points tall")
        #expect(height <= 36, "\(fixture) footer expanded to \(height) points")
    }
}

enum FooterFixture: CaseIterable, CustomStringConvertible, Sendable {
    case loading
    case populated
    case multiWindow
    case stale
    case error
    case refreshing

    var description: String {
        switch self {
        case .loading: "loading"
        case .populated: "populated"
        case .multiWindow: "multi-window"
        case .stale: "stale"
        case .error: "error"
        case .refreshing: "refreshing"
        }
    }

    var snapshots: [ProviderUsageSnapshot] {
        switch self {
        case .loading:
            return CLIUsageService.displayedKinds.map {
                ProviderUsageSnapshot(provider: $0, state: .loading, windows: [], fetchedAt: nil)
            }
        case .error:
            return CLIUsageService.displayedKinds.map {
                ProviderUsageSnapshot(
                    provider: $0,
                    state: .unavailable(reason: "Quota unavailable."),
                    windows: [],
                    fetchedAt: nil
                )
            }
        case .stale:
            return CLIUsageService.displayedKinds.map {
                snapshot(
                    provider: $0,
                    windows: [window(
                        provider: $0,
                        key: realisticWindows(for: $0)[0].key,
                        label: realisticWindows(for: $0)[0].label,
                        stale: true
                    )]
                )
            }
        case .multiWindow:
            return CLIUsageService.displayedKinds.map { provider in
                snapshot(
                    provider: provider,
                    windows: realisticWindows(for: provider).map { item in
                        window(
                            provider: provider,
                            key: item.key,
                            label: item.label
                        )
                    }
                )
            }
        case .populated, .refreshing:
            return CLIUsageService.displayedKinds.map {
                snapshot(
                    provider: $0,
                    windows: [window(
                        provider: $0,
                        key: realisticWindows(for: $0)[0].key,
                        label: realisticWindows(for: $0)[0].label
                    )]
                )
            }
        }
    }

    private func realisticWindows(for provider: AgentKind) -> [(key: String, label: String)] {
        switch provider {
        case .codex:
            [("primary", "5 hr"), ("secondary", "Weekly")]
        case .claude:
            [("five_hour", "5 hr"), ("seven_day", "Weekly"), ("limit.opus", "Opus"), ("limit.sonnet", "Sonnet")]
        case .grok:
            [("included", "Included"), ("on_demand", "On demand")]
        case .cursor:
            [("cursor_models", "Cursor Models"), ("other_models", "Other Models")]
        default:
            [("primary", "Usage")]
        }
    }

    private func snapshot(
        provider: AgentKind,
        windows: [ProviderUsageWindow]
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            state: windows.contains(where: { window in
                if case .stale = window.freshness { return true }
                return false
            }) ? .stale(reason: "Refresh timed out.") : .available,
            windows: windows,
            fetchedAt: Date(timeIntervalSince1970: 1_777_636_800)
        )
    }

    private func window(
        provider: AgentKind,
        key: String,
        label: String,
        stale: Bool = false
    ) -> ProviderUsageWindow {
        let fetchedAt = Date(timeIntervalSince1970: 1_777_636_800)
        return ProviderUsageWindow(
            value: ProviderUsageWindowValue(
                id: ProviderUsageWindowID(provider: provider, key: key),
                label: label,
                remainingPercent: 64,
                resetsAt: fetchedAt.addingTimeInterval(3_600)
            ),
            freshness: stale
                ? .stale(reason: "Refresh timed out.", lastSuccessfulAt: fetchedAt)
                : .fresh,
            lastSuccessfulAt: fetchedAt
        )
    }
}
