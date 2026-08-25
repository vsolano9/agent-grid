import SwiftUI
import UniformTypeIdentifiers

struct GridSetupView: View {
    let grid: AgentGridTab
    let maintenanceWarnings: [AgentKind]
    let setAgent: (AgentKind, AgentPanePosition) -> Void
    let setWorkingDirectory: (URL) -> Void
    let launch: () -> Void

    @State private var isChoosingDirectory = false
    @State private var directoryError: String?

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 26) {
                header
                if !maintenanceWarnings.isEmpty {
                    maintenanceWarning
                }
                selectors
                workspaceLocation

                Button(action: launch) {
                    Text("Launch \(grid.title)")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.92, green: 0.45, blue: 0.12))
                .accessibilityHint("Starts four agent terminals with the selected command line tools")
            }
            .padding(32)
            .frame(width: 500)
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
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let directory = urls.first {
                    directoryError = nil
                    setWorkingDirectory(directory)
                }
            case let .failure(error):
                directoryError = error.localizedDescription
            }
        }
    }

    private var maintenanceWarning: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text("Update unavailable for \(warningNames); the installed command was verified and remains available.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var warningNames: String {
        maintenanceWarnings.map(\.displayName).joined(separator: ", ")
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                .accessibilityHidden(true)

            Text("Configure \(grid.title)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))

            Text("Choose one CLI for each pane. Repeating a CLI is allowed.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
    }

    private var selectors: some View {
        VStack(spacing: 0) {
            ForEach(AgentPanePosition.allCases, id: \.self) { position in
                HStack(spacing: 16) {
                    Text(position.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.76))

                    Spacer(minLength: 12)

                    Picker(
                        position.displayName,
                        selection: Binding(
                            get: { grid.draftSelection.agent(at: position) },
                            set: { setAgent($0, position) }
                        )
                    ) {
                        ForEach(AgentKind.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170, alignment: .trailing)
                    .accessibilityLabel("\(position.displayName) CLI")
                }
                .frame(minHeight: 46)
                .padding(.horizontal, 16)

                if position != .bottomRight {
                    Divider()
                        .overlay(Color.white.opacity(0.1))
                        .padding(.leading, 16)
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

    private var workspaceLocation: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Working directory")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.54))

                    Text(grid.draftWorkingDirectory.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(grid.draftWorkingDirectory.path)
                }

                Spacer(minLength: 12)

                Button("Change…") {
                    isChoosingDirectory = true
                }
                .controlSize(.small)
                .accessibilityHint("Chooses the working directory for this grid")
            }

            if let directoryError {
                Text(directoryError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Working directory error: \(directoryError)")
            }
        }
    }
}
