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
    func signedInAccountsExposeQuota() async throws {
        let snapshots = try await CLIUsageService.live().fetch()

        for kind in CLIUsageService.displayedKinds {
            guard let snapshot = snapshots.first(where: { $0.provider == kind }),
                  snapshot.state == .available,
                  snapshot.windows.contains(where: { $0.freshness == .fresh }) else {
                Issue.record("\(kind.displayName) did not return live quota windows.")
                continue
            }
            #expect(snapshot.windows.allSatisfy { (0 ... 100).contains($0.remainingPercent) })
            #expect(snapshot.windows.allSatisfy { window in
                window.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true
            })
        }
    }
}
