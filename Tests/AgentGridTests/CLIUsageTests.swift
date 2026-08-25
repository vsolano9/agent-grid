import Foundation
import Testing
@testable import AgentGrid

struct CLIUsageTests {
    @Test("Codex quota parser converts used percent into bounded remaining percent", arguments: [
        (used: -4, remaining: 100),
        (used: 49, remaining: 51),
        (used: 140, remaining: 0),
    ])
    func codexRemainingPercentage(values: (used: Int, remaining: Int)) throws {
        let payload = """
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":\(values.used)}}}}
        """

        let reading = try CodexUsageResponseParser.parse(payload)

        #expect(reading == .available(remainingPercent: values.remaining))
    }

    @Test("Codex quota parser rejects successful protocol messages without a quota window")
    func codexMissingQuota() {
        #expect(throws: CLIUsageError.missingQuota) {
            try CodexUsageResponseParser.parse("{\"id\":2,\"result\":{\"rateLimits\":{}}}")
        }
    }

    @MainActor
    @Test("Usage model always publishes one ordered honest state per CLI")
    func usageModelNormalizesProviderResults() async {
        let reader = StubCLIUsageReader(readings: [
            .codex: .available(remainingPercent: 55),
            .claude: .unavailable(reason: "Claude does not expose account quota to scripts."),
        ])
        let model = CLIUsageModel(reader: reader)

        #expect(model.entries.map(\.state) == Array(repeating: .loading, count: 5))

        await model.start()

        #expect(model.entries.map(\.kind) == AgentKind.allCases)
        #expect(model.entries[0].state == .available(remainingPercent: 55))
        #expect(model.entries[1].state == .unavailable(reason: "Claude does not expose account quota to scripts."))
        #expect(model.entries.dropFirst(2).allSatisfy {
            $0.state == .unavailable(reason: "Account quota is not exposed by this CLI.")
        })
        #expect(await reader.callCount == 1)
    }

    @MainActor
    @Test("Usage model permits a manual refresh after the initial reading")
    func usageModelRefreshes() async {
        let reader = StubCLIUsageReader(readings: [
            .codex: .available(remainingPercent: 51),
        ])
        let model = CLIUsageModel(reader: reader)

        await model.start()
        await model.refresh()

        #expect(await reader.callCount == 2)
        #expect(model.entries[0].state == .available(remainingPercent: 51))
    }
}

private actor StubCLIUsageReader: CLIUsageReading {
    private let readings: [AgentKind: CLIUsageState]
    private(set) var callCount = 0

    init(readings: [AgentKind: CLIUsageState]) {
        self.readings = readings
    }

    func fetch() async -> [AgentKind: CLIUsageState] {
        callCount += 1
        return readings
    }
}
