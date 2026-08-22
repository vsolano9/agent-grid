import CoreGraphics
import Foundation
import Testing
@testable import AgentGrid

struct RuntimePolicyTests {
    @Test("The Work root is preferred when it exists")
    func preferredWorkspace() {
        let work = URL(fileURLWithPath: "/Volumes/Extreme Pro/Documents/Work")
        let home = URL(fileURLWithPath: "/home/test")
        let locator = WorkspaceLocator(
            preferredWorkspace: work,
            homeDirectory: home,
            isDirectory: { $0 == work }
        )

        #expect(locator.workspace() == work)
    }

    @Test("Home is used when the Work root is unavailable")
    func homeFallback() {
        let home = URL(fileURLWithPath: "/home/test")
        let locator = WorkspaceLocator(
            preferredWorkspace: URL(fileURLWithPath: "/missing"),
            homeDirectory: home,
            isDirectory: { _ in false }
        )

        #expect(locator.workspace() == home)
    }

    @Test("Terminal environment adds truecolor and Finder-safe executable paths")
    func terminalEnvironment() throws {
        let environment = TerminalEnvironment.make(
            base: ["PATH": "/custom/bin", "LANG": "en_US.UTF-8"],
            homeDirectory: URL(fileURLWithPath: "/home/test")
        )
        let path = try #require(environment["PATH"])

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(path.split(separator: ":").map(String.init) == [
            "/custom/bin",
            "/home/test/.local/bin",
            "/home/test/.grok/bin",
            "/home/test/.cursor/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])
    }

    @Test("Maximized windows use the screen's visible frame")
    func maximizedFrame() {
        let visibleFrame = CGRect(x: 0, y: 48, width: 1728, height: 1069)

        #expect(WindowFramePolicy.maximizedFrame(for: visibleFrame) == visibleFrame)
    }
}
