import Foundation
import Testing
@testable import AgentGrid

struct LiveProviderUsageTests {
    @Test(
        "Signed-in provider accounts expose live quota percentages",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/AgentGridLiveUsageTests.enabled"
        ))
    )
    func signedInAccountsExposeQuota() async {
        let states = await CLIUsageService.live().fetch()

        for kind in CLIUsageService.displayedKinds {
            guard case let .available(remainingPercent) = states[kind] else {
                Issue.record("\(kind.displayName) did not return a live quota: \(String(describing: states[kind]))")
                continue
            }
            #expect((0 ... 100).contains(remainingPercent))
        }
    }
}
