import SwiftUI

struct CLIUsageBar: View {
    static let height: CGFloat = 32

    let snapshots: [ProviderUsageSnapshot]
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(orderedSnapshots) { snapshot in
                CLIUsageSegment(snapshot: snapshot)

                if snapshot.id != orderedSnapshots.last?.id {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                        .padding(.vertical, 3)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 3)

            CLIUsageRefreshButton(
                isRefreshing: isRefreshing,
                refresh: refresh
            )
        }
        .frame(height: Self.height)
        .background(Color(red: 0.075, green: 0.08, blue: 0.085))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }

    private var orderedSnapshots: [ProviderUsageSnapshot] {
        ProviderUsagePresentation.orderedSnapshots(snapshots)
    }
}
