import AppKit
import Darwin
import SwiftUI

@main
struct FocusStealFixtureApp: App {
    private let programmaticMode = CommandLine.arguments.contains("--programmatic")
    @State private var preconditionStatus = "Inactive precondition: pending"

    var body: some Scene {
        Window("AgentGrid Focus Steal Fixture", id: "main") {
            VStack(spacing: 16) {
                Text("AgentGrid Focus Steal Fixture — Test Only")
                    .font(.headline)
                Text(programmaticMode
                     ? "Programmatic activation mode"
                     : "Explicit user activation mode")
                    .foregroundStyle(.secondary)
                if programmaticMode {
                    Text(preconditionStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Activate Fixture") {
                    NSApp.activate()
                }
            }
            .padding(32)
            .task {
                guard programmaticMode else { return }
                let coordinator = ProgrammaticFocusStealCoordinator(
                    clock: ContinuousClock(),
                    application: AppKitFocusStealApplication(),
                    receipt: { receipt in
                        preconditionStatus = receipt
                        writeFixtureReceipt(receipt)
                    }
                )
                do {
                    try await coordinator.run()
                } catch is CancellationError {
                    return
                } catch {
                    writeFixtureReceipt("programmatic-focus-steal-aborted")
                    Darwin.exit(2)
                }
            }
        }
        .defaultSize(width: 460, height: 220)
    }
}

@MainActor
private final class AppKitFocusStealApplication: FocusStealApplicationControlling {
    var isActive: Bool { NSApp.isActive }
    func deactivate() { NSApp.deactivate() }
    func activate() { NSApp.activate() }
}

@MainActor
private func writeFixtureReceipt(_ receipt: String) {
    guard let data = "FocusStealFixture: \(receipt)\n".data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: data)
}
