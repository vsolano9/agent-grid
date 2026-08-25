import SwiftUI

struct CLIMaintenanceView: View {
    let phase: CLIMaintenancePhase
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 24) {
                header
                progress
                statusRows

                if case .failed = phase {
                    Button("Retry CLI Maintenance", action: retry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Color(red: 0.92, green: 0.45, blue: 0.12))
                        .accessibilityHint("Attempts every supported CLI update and alias check again")
                }
            }
            .padding(32)
            .frame(width: 520)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.105, green: 0.11, blue: 0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.13), lineWidth: 1)
            }
            .padding(32)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                .accessibilityHidden(true)

            Text(isFailed ? "CLI maintenance needs attention" : "Updating command line tools")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))

            Text(
                isFailed
                    ? "Repair the failed command before launching unrestricted terminals."
                    : "AgentGrid is updating and verifying every CLI before terminal setup."
            )
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.62))
            .multilineTextAlignment(.center)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: Double(completedCount), total: Double(AgentKind.allCases.count))
                .tint(Color(red: 0.92, green: 0.45, blue: 0.12))

            Text("\(completedCount) of \(AgentKind.allCases.count) CLIs verified")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.54))
                .accessibilityLabel("\(completedCount) of \(AgentKind.allCases.count) command line tools verified")
        }
    }

    private var statusRows: some View {
        VStack(spacing: 0) {
            ForEach(AgentKind.allCases, id: \.self) { kind in
                HStack(spacing: 12) {
                    statusIcon(for: kind)
                        .frame(width: 18)

                    Text(kind.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))

                    Spacer(minLength: 12)

                    Text(statusText(for: kind))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(statusColor(for: kind))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)

                if kind != .hermes {
                    Divider()
                        .overlay(Color.white.opacity(0.1))
                        .padding(.leading, 44)
                }
            }
        }
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func statusIcon(for kind: AgentKind) -> some View {
        if activeKind == kind {
            ProgressView()
                .controlSize(.small)
        } else if let entry = entry(for: kind) {
            switch entry.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .readyWithWarning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Image(systemName: "circle")
                .foregroundStyle(Color.white.opacity(0.28))
        }
    }

    private func statusText(for kind: AgentKind) -> String {
        if activeKind == kind { return "Updating…" }
        guard let entry = entry(for: kind) else { return "Pending" }
        switch entry.state {
        case let .ready(version): return version
        case let .readyWithWarning(version): return "Verified \(version)"
        case let .failed(reason): return reason
        }
    }

    private func statusColor(for kind: AgentKind) -> Color {
        guard let entry = entry(for: kind) else { return Color.white.opacity(0.42) }
        switch entry.state {
        case .ready: return Color.white.opacity(0.68)
        case .readyWithWarning: return .yellow
        case .failed: return .red
        }
    }

    private func entry(for kind: AgentKind) -> CLIMaintenanceEntry? {
        entries.first { $0.kind == kind }
    }

    private var entries: [CLIMaintenanceEntry] {
        switch phase {
        case .idle: []
        case let .running(progress): progress.entries
        case let .ready(report), let .failed(report): report.entries
        }
    }

    private var activeKind: AgentKind? {
        guard case let .running(progress) = phase else { return nil }
        return progress.activeKind
    }

    private var completedCount: Int {
        switch phase {
        case .idle: 0
        case let .running(progress): progress.completedCount
        case let .ready(report), let .failed(report):
            report.entries.filter { $0.state.isReady }.count
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
