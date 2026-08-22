import CoreGraphics

struct TerminalLaunchGate {
    private var hasLaunched = false

    mutating func beginIfReady(
        isAttached: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        guard !hasLaunched, isAttached, width > 0, height > 0 else {
            return false
        }

        hasLaunched = true
        return true
    }
}
