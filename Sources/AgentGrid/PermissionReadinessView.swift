import SwiftUI

struct PermissionReadinessView: View {
    let readiness: PermissionReadiness

    var body: some View {
        if !readiness.issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(readiness.issues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(PermissionReadinessPresentation.message(for: issue))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(PermissionReadinessPresentation.actionTitle(for: issue)) {
                            readiness.openSettings(for: issue)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: 620, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.orange.opacity(0.7), lineWidth: 1)
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AgentGrid permission readiness")
        }
    }
}
