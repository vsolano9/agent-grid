import AppKit
import Observation
import SwiftUI

enum WindowFramePolicy {
    static func maximizedFrame(for visibleFrame: CGRect) -> CGRect {
        visibleFrame
    }
}

@MainActor
@Observable
final class AgentGridWindowState {
    var isPrepared = false
}

struct WindowMaximizer: NSViewRepresentable {
    let state: AgentGridWindowState

    func makeNSView(context: Context) -> MaximizingView {
        MaximizingView(state: state)
    }

    func updateNSView(_ nsView: MaximizingView, context: Context) {}

    final class MaximizingView: NSView {
        private let state: AgentGridWindowState
        private var hasMaximized = false

        init(state: AgentGridWindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard hasMaximized == false,
                  let window,
                  let screen = window.screen ?? NSScreen.main else {
                return
            }

            hasMaximized = true
            window.tabbingMode = .disallowed
            window.setFrame(
                WindowFramePolicy.maximizedFrame(for: screen.visibleFrame),
                display: true,
                animate: false
            )
            window.makeKeyAndOrderFront(nil)

            DispatchQueue.main.async { [state] in
                state.isPrepared = true
            }
        }
    }
}
