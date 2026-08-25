import SwiftUI

struct CLIUsageSegment: View {
    let entry: CLIUsageEntry
    let animationDelay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(shortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                value
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Color(red: 0.92, green: 0.45, blue: 0.12))
                        .frame(width: proxy.size.width * fillFraction)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18).delay(animationDelay),
            value: fillFraction
        )
    }

    @ViewBuilder
    private var value: some View {
        switch entry.state {
        case .loading:
            if reduceMotion {
                Text("…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        case let .available(remainingPercent):
            Text("\(remainingPercent)% left")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        case let .stale(remainingPercent, _):
            Text("\(remainingPercent)% left")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var shortName: String {
        switch entry.kind {
        case .cursor: "Cursor"
        case .hermes: "Hermes"
        default: entry.kind.displayName
        }
    }

    private var fillFraction: Double {
        switch entry.state {
        case let .available(remainingPercent), let .stale(remainingPercent, _):
            return Double(min(max(remainingPercent, 0), 100)) / 100
        case .loading, .unavailable:
            return 0
        }
    }

    private var helpText: String {
        switch entry.state {
        case .loading: "Refreshing \(shortName) account quota."
        case let .available(remainingPercent):
            "\(shortName) account quota: \(remainingPercent) percent remaining."
        case let .stale(remainingPercent, reason):
            "\(shortName) account quota: \(remainingPercent) percent remaining from the last successful refresh. \(reason)"
        case let .unavailable(reason): reason
        }
    }

    private var accessibilityText: String { helpText }
}
