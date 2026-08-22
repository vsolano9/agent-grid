import AppKit
import SwiftTerm
import SwiftUI

struct TerminalPane: NSViewRepresentable {
    let spec: AgentLaunchSpec
    let environment: [String: String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LaunchingTerminalView {
        let terminal = LaunchingTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: .default
        )
        terminal.processDelegate = context.coordinator
        terminal.nativeBackgroundColor = NSColor(white: 0.025, alpha: 1)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(NSAccessibility.Role.textArea)
        terminal.setAccessibilityLabel("\(spec.kind.rawValue.capitalized) terminal")
        terminal.launchWhenReady { [weak terminal] in
            terminal?.startProcess(
                executable: spec.executable.path,
                args: spec.arguments,
                environment: TerminalEnvironment.processVariables(environment),
                execName: spec.kind.executableName,
                currentDirectory: spec.workingDirectory.path
            )
        }
        return terminal
    }

    func updateNSView(_ nsView: LaunchingTerminalView, context: Context) {}

    static func dismantleNSView(
        _ nsView: LaunchingTerminalView,
        coordinator: Coordinator
    ) {
        nsView.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(
            source: LocalProcessTerminalView,
            newCols: Int,
            newRows: Int
        ) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

final class LaunchingTerminalView: LocalProcessTerminalView {
    private var launchGate = TerminalLaunchGate()
    private var launchHandler: (() -> Void)?

    func launchWhenReady(_ handler: @escaping () -> Void) {
        launchHandler = handler
        launchIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        launchIfReady()
    }

    override func layout() {
        super.layout()
        launchIfReady()
    }

    private func launchIfReady() {
        guard launchGate.beginIfReady(
            isAttached: window != nil,
            width: bounds.width,
            height: bounds.height
        ) else {
            return
        }

        let handler = launchHandler
        launchHandler = nil
        handler?()
    }
}
