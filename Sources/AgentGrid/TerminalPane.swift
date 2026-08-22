import AppKit
import SwiftTerm
import SwiftUI

struct TerminalPane: NSViewRepresentable {
    let spec: AgentLaunchSpec
    let environment: [String: String]
    let isWindowPrepared: Bool
    let isGridActive: Bool
    let prefersFocus: Bool

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
        terminal.updateWindowReadiness(isPrepared: isWindowPrepared)
        terminal.updateGridActivation(
            isActive: isGridActive,
            prefersFocus: prefersFocus
        )
        return terminal
    }

    func updateNSView(_ nsView: LaunchingTerminalView, context: Context) {
        nsView.updateWindowReadiness(isPrepared: isWindowPrepared)
        nsView.updateGridActivation(
            isActive: isGridActive,
            prefersFocus: prefersFocus
        )
    }

    static func dismantleNSView(
        _ nsView: LaunchingTerminalView,
        coordinator: Coordinator
    ) {
        nsView.terminateAndReap()
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
    private var activationGate = TerminalActivationGate()
    private var launchHandler: (() -> Void)?
    private var isWindowPrepared = false
    private var shouldFocusWhenAttached = false

    func launchWhenReady(_ handler: @escaping () -> Void) {
        launchHandler = handler
        scheduleLaunchIfReady()
    }

    func updateGridActivation(isActive: Bool, prefersFocus: Bool) {
        setAccessibilityHidden(!isActive)

        if !isActive {
            shouldFocusWhenAttached = false
        }

        if activationGate.shouldClaimFocus(
            isActive: isActive,
            prefersFocus: prefersFocus
        ) {
            shouldFocusWhenAttached = true
            focusIfReady()
        }
    }

    func updateWindowReadiness(isPrepared: Bool) {
        isWindowPrepared = isPrepared
        scheduleLaunchIfReady()
    }

    func terminateAndReap() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(performDeferredLaunch),
            object: nil
        )
        let pid = process.shellPid
        terminate()
        ChildProcessReaper.live.reap(pid)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleLaunchIfReady()
        focusIfReady()
    }

    override func layout() {
        super.layout()
        scheduleLaunchIfReady()
    }

    private func scheduleLaunchIfReady() {
        guard launchHandler != nil,
              isWindowPrepared,
              window != nil,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(performDeferredLaunch),
            object: nil
        )
        perform(
            #selector(performDeferredLaunch),
            with: nil,
            afterDelay: 0.2
        )
    }

    @objc
    private func performDeferredLaunch() {
        guard launchGate.beginIfReady(
            isWindowPrepared: isWindowPrepared,
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

    private func focusIfReady() {
        guard shouldFocusWhenAttached, let window else { return }

        shouldFocusWhenAttached = false
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
        }
    }
}
