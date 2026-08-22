import AppKit
import SwiftUI

enum WindowFramePolicy {
    static func maximizedFrame(for visibleFrame: CGRect) -> CGRect {
        visibleFrame
    }
}

struct WindowMaximizer: NSViewRepresentable {
    func makeNSView(context: Context) -> MaximizingView {
        MaximizingView()
    }

    func updateNSView(_ nsView: MaximizingView, context: Context) {}

    final class MaximizingView: NSView {
        private var hasMaximized = false

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
        }
    }
}
