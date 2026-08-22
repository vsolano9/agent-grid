import CoreGraphics
import Darwin
import Foundation

struct TerminalLaunchGate {
    private var hasLaunched = false

    mutating func beginIfReady(
        isWindowPrepared: Bool,
        isAttached: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        guard !hasLaunched,
              isWindowPrepared,
              isAttached,
              width > 0,
              height > 0 else {
            return false
        }

        hasLaunched = true
        return true
    }
}

struct TerminalActivationGate {
    private var wasActive = false

    mutating func shouldClaimFocus(
        isActive: Bool,
        prefersFocus: Bool
    ) -> Bool {
        defer { wasActive = isActive }
        return isActive && !wasActive && prefersFocus
    }
}

struct ChildProcessReaper: Sendable {
    static let live = ChildProcessReaper()

    private let queue: DispatchQueue
    private let waitForExit: @Sendable (pid_t) -> Void

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "AgentGrid.ChildProcessReaper",
            qos: .utility,
            attributes: .concurrent
        ),
        waitForExit: @escaping @Sendable (pid_t) -> Void = ChildProcessReaper.waitForChildExit
    ) {
        self.queue = queue
        self.waitForExit = waitForExit
    }

    func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        queue.async { [waitForExit] in
            waitForExit(pid)
        }
    }

    static func waitForChildExit(_ pid: pid_t) {
        var status: Int32 = 0

        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return }
        }
    }
}
