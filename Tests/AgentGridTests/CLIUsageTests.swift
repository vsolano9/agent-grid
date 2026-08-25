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

        #expect(reading == values.remaining)
    }

    @Test("Codex quota parser rejects successful protocol messages without a quota window")
    func codexMissingQuota() {
        #expect(throws: CLIUsageError.missingQuota) {
            try CodexUsageResponseParser.parse("{\"id\":2,\"result\":{\"rateLimits\":{}}}")
        }
    }

    @MainActor
    @Test("Usage model publishes only the four account quota providers in order")
    func usageModelNormalizesProviderResults() async {
        let reader = StubCLIUsageReader(readings: [
            .codex: .available(remainingPercent: 55),
            .claude: .unavailable(reason: "Claude does not expose account quota to scripts."),
        ])
        let model = CLIUsageModel(reader: reader)

        #expect(model.entries.map(\.state) == Array(repeating: .loading, count: 4))

        await model.start()

        #expect(model.entries.map(\.kind) == [.codex, .claude, .grok, .cursor])
        #expect(model.entries[0].state == .available(remainingPercent: 55))
        #expect(model.entries[1].state == .unavailable(reason: "Claude does not expose account quota to scripts."))
        #expect(model.entries.dropFirst(2).allSatisfy {
            $0.state == .unavailable(reason: "Account quota is not exposed by this CLI.")
        })
        #expect(await reader.callCount == 1)
    }

    @Test("Usage service keeps a last-good provider value when the next refresh fails")
    func usageServiceKeepsLastGoodValue() async {
        let codex = SequencedProviderQuotaReader(results: [
            .success(55),
            .failure(TestUsageError.offline),
        ])
        let service = CLIUsageService(readers: [.codex: codex])

        let first = await service.fetch()
        let second = await service.fetch()

        #expect(first[.codex] == .available(remainingPercent: 55))
        #expect(second[.codex] == .stale(
            remainingPercent: 55,
            reason: "Codex quota could not be refreshed."
        ))
        #expect(second[.hermes] == nil)
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

private enum TestUsageError: Error {
    case offline
}

private actor SequencedProviderQuotaReader: ProviderQuotaReading {
    private var results: [Result<Int, Error>]

    init(results: [Result<Int, Error>]) {
        self.results = results
    }

    func fetchRemainingPercent() async throws -> Int {
        guard !results.isEmpty else { throw TestUsageError.offline }
        return try results.removeFirst().get()
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
