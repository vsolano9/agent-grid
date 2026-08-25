import SwiftUI

struct CLIUsageRefreshButton: View {
    let isRefreshing: Bool
    let refresh: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees = 0.0

    var body: some View {
        Button(action: refresh) {
            Label("Refresh CLI usage", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
                .rotationEffect(.degrees(rotationDegrees))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isRefreshing ? .orange : .secondary)
        .disabled(isRefreshing)
        .frame(width: 28)
        .frame(maxHeight: .infinity)
        .accessibilityHint("Refreshes supported account quota readings")
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing else { return }
            if reduceMotion {
                rotationDegrees += 360
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    rotationDegrees += 360
                }
            }
        }
    }
}
