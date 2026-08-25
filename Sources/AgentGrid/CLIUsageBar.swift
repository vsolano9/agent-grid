import SwiftUI

struct CLIUsageBar: View {
    let entries: [CLIUsageEntry]
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                CLIUsageSegment(entry: entry, animationDelay: Double(index) * 0.025)

                if entry.id != entries.last?.id {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                        .padding(.vertical, 8)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 8)

            Button("Refresh CLI usage", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isRefreshing)
                .frame(width: 38, height: 40)
                .accessibilityHint("Refreshes supported account quota readings")
        }
        .frame(height: 42)
        .background(Color(red: 0.075, green: 0.08, blue: 0.085))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }
}
