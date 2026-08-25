import Foundation
import Testing
@testable import AgentGrid

struct CLIUsageTests {
    @Test("Usage service publishes exactly four provider snapshots in display order")
    func serviceOrdersProviderSnapshots() async throws {
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.codex, "primary", "Weekly", 55))
                )),
            ]),
        ])

        let snapshots = try await service.fetch()

        #expect(snapshots.map(\.provider) == [.codex, .claude, .grok, .cursor])
        #expect(snapshots[0].windows.map(\.remainingPercent) == [55])
        #expect(snapshots.dropFirst().allSatisfy { snapshot in
            if case .unavailable = snapshot.state { return true }
            return false
        })
    }

    @Test("Semantic window IDs stay attached to values when provider order changes")
    func semanticIDsSurviveReordering() async throws {
        let service = CLIUsageService(readers: [
            .claude: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.claude, "seven_day", "Weekly", 25)),
                    .available(value(.claude, "five_hour", "5 hr", 80))
                )),
                .success(observation(
                    at: Date(timeIntervalSince1970: 200),
                    .available(value(.claude, "five_hour", "5 hr", 70)),
                    .available(value(.claude, "seven_day", "Weekly", 20))
                )),
            ]),
        ])

        _ = try await service.fetch()
        let second = try #require(try await service.fetch().first { $0.provider == .claude })

        #expect(second.windows.map(\.id) == [
            ProviderUsageWindowID(provider: .claude, key: "five_hour"),
            ProviderUsageWindowID(provider: .claude, key: "seven_day"),
        ])
        #expect(second.windows.map(\.remainingPercent) == [70, 20])
    }

    @Test("A successful window replaces only itself while a malformed peer becomes stale")
    func partialObservationMergesPerWindow() async throws {
        let firstReset = Date(timeIntervalSince1970: 1_000)
        let secondReset = Date(timeIntervalSince1970: 2_000)
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.codex, "primary", "5 hr", 60, resetsAt: firstReset)),
                    .available(value(.codex, "secondary", "Weekly", 40, resetsAt: secondReset))
                )),
                .success(observation(
                    at: Date(timeIntervalSince1970: 200),
                    .available(value(.codex, "primary", "5 hr", 55, resetsAt: firstReset)),
                    .failed(
                        id: ProviderUsageWindowID(provider: .codex, key: "secondary"),
                        reason: "Codex weekly quota was malformed."
                    )
                )),
            ]),
        ])

        _ = try await service.fetch()
        let second = try #require(try await service.fetch().first { $0.provider == .codex })
        let primary = try #require(second.windows.first { $0.id.key == "primary" })
        let secondary = try #require(second.windows.first { $0.id.key == "secondary" })

        #expect(primary.remainingPercent == 55)
        #expect(primary.freshness == .fresh)
        #expect(secondary.remainingPercent == 40)
        #expect(secondary.resetsAt == secondReset)
        #expect(secondary.freshness == .stale(
            reason: "Codex weekly quota was malformed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(second.state == .available)
    }

    @Test("A malformed Codex duration retains the entire last-good window as stale")
    func codexMalformedDurationRetainsStaleWindow() async throws {
        let first = try CodexUsageResponseParser.parseObservation(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":null}}}"#,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let second = try CodexUsageResponseParser.parseObservation(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":"bad"},"secondary":null}}}"#,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [.success(first), .success(second)]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .codex })
        let primary = try #require(snapshot.windows.first { $0.id.key == "primary" })

        #expect(snapshot.state == .stale(reason: "Codex primary quota was malformed."))
        #expect(primary.label == "5 hr")
        #expect(primary.remainingPercent == 80)
        #expect(primary.freshness == .stale(
            reason: "Codex primary quota was malformed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test(
        "Invalid numeric Codex durations retain the last-good window without trapping",
        arguments: ["1e300", "300.5", "-300", "0"]
    )
    func codexInvalidNumericDurationRetainsStaleWindow(rawDuration: String) async throws {
        let first = try CodexUsageResponseParser.parseObservation(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":null}}}"#,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let second = try CodexUsageResponseParser.parseObservation(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":\#(rawDuration)},"secondary":null}}}"#,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [.success(first), .success(second)]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .codex })
        let primary = try #require(snapshot.windows.first { $0.id.key == "primary" })

        #expect(snapshot.state == .stale(reason: "Codex primary quota was malformed."))
        #expect(primary.label == "5 hr")
        #expect(primary.remainingPercent == 80)
        #expect(primary.freshness == .stale(
            reason: "Codex primary quota was malformed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("A cached window omitted by a successful refresh becomes stale, never fresh")
    func successfulOmissionStalesCachedWindow() async throws {
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.codex, "primary", "5 hr", 60)),
                    .available(value(.codex, "secondary", "Weekly", 40))
                )),
                .success(observation(
                    at: Date(timeIntervalSince1970: 200),
                    .available(value(.codex, "primary", "5 hr", 55))
                )),
            ]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .codex })
        let omitted = try #require(snapshot.windows.first { $0.id.key == "secondary" })

        #expect(snapshot.state == .available)
        #expect(omitted.remainingPercent == 40)
        #expect(omitted.freshness == .stale(
            reason: "Codex secondary quota was omitted from the latest response.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("An all-failed first observation makes the provider unavailable")
    func allFailedFirstObservationIsUnavailable() async throws {
        let service = CLIUsageService(readers: [
            .claude: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .failed(
                        id: ProviderUsageWindowID(provider: .claude, key: "five_hour"),
                        reason: "Claude five_hour quota was malformed."
                    ),
                    .failed(
                        id: ProviderUsageWindowID(provider: .claude, key: "seven_day"),
                        reason: "Claude seven_day quota was malformed."
                    )
                )),
            ]),
        ])

        let snapshot = try #require(try await service.fetch().first { $0.provider == .claude })

        #expect(snapshot.state == .unavailable(
            reason: "Claude five_hour quota was malformed."
        ))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("An observation retaining only stale last-good windows makes the provider stale")
    func allRetainedWindowsAreProviderStale() async throws {
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.grok, "included", "Weekly", 50))
                )),
                .success(observation(
                    at: Date(timeIntervalSince1970: 200),
                    .failed(
                        id: ProviderUsageWindowID(provider: .grok, key: "included"),
                        reason: "Grok included quota was malformed."
                    )
                )),
            ]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })

        #expect(snapshot.state == .stale(reason: "Grok included quota was malformed."))
        #expect(snapshot.windows.first?.freshness == .stale(
            reason: "Grok included quota was malformed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("A provider failure stales all of its last-good windows without changing peers")
    func providerFailureIsIsolated() async throws {
        let codex = SequencedProviderQuotaReader(results: [
            .success(observation(
                at: Date(timeIntervalSince1970: 100),
                .available(value(.codex, "primary", "5 hr", 55)),
                .available(value(.codex, "secondary", "Weekly", 35))
            )),
            .failure(TestUsageError.offline),
        ])
        let claude = SequencedProviderQuotaReader(results: [
            .success(observation(
                at: Date(timeIntervalSince1970: 100),
                .available(value(.claude, "five_hour", "5 hr", 75))
            )),
            .success(observation(
                at: Date(timeIntervalSince1970: 200),
                .available(value(.claude, "five_hour", "5 hr", 70))
            )),
        ])
        let service = CLIUsageService(readers: [.codex: codex, .claude: claude])

        _ = try await service.fetch()
        let second = try await service.fetch()
        let codexSnapshot = try #require(second.first { $0.provider == .codex })
        let claudeSnapshot = try #require(second.first { $0.provider == .claude })

        #expect(codexSnapshot.state == .stale(reason: "Codex quota could not be refreshed."))
        #expect(codexSnapshot.windows.allSatisfy { window in
            window.freshness == .stale(
                reason: "Codex quota could not be refreshed.",
                lastSuccessfulAt: Date(timeIntervalSince1970: 100)
            )
        })
        #expect(claudeSnapshot.state == .available)
        #expect(claudeSnapshot.windows.map(\.remainingPercent) == [70])
        #expect(claudeSnapshot.windows.allSatisfy { $0.freshness == .fresh })
    }

    @Test("An explicitly inactive window removes its last-good value")
    func explicitRemovalDropsWindow() async throws {
        let secondaryID = ProviderUsageWindowID(provider: .codex, key: "secondary")
        let service = CLIUsageService(readers: [
            .codex: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.codex, "primary", "5 hr", 60)),
                    .available(value(.codex, "secondary", "Weekly", 40))
                )),
                .success(observation(
                    at: Date(timeIntervalSince1970: 200),
                    .available(value(.codex, "primary", "5 hr", 58)),
                    .removed(secondaryID)
                )),
            ]),
        ])

        _ = try await service.fetch()
        let second = try #require(try await service.fetch().first { $0.provider == .codex })

        #expect(second.windows.map(\.id.key) == ["primary"])
    }

    @Test("Cursor legacy and two-pool transitions remove obsolete semantic windows")
    func cursorWindowModeTransitions() async throws {
        let twoPool = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let legacy = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"totalPercentUsed":20}}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let toLegacy = CLIUsageService(readers: [
            .cursor: SequencedProviderQuotaReader(results: [.success(twoPool), .success(legacy)]),
        ])
        _ = try await toLegacy.fetch()
        let legacySnapshot = try #require(try await toLegacy.fetch().first { $0.provider == .cursor })

        let toPools = CLIUsageService(readers: [
            .cursor: SequencedProviderQuotaReader(results: [.success(legacy), .success(twoPool)]),
        ])
        _ = try await toPools.fetch()
        let poolsSnapshot = try #require(try await toPools.fetch().first { $0.provider == .cursor })

        #expect(legacySnapshot.windows.map(\.id.key) == ["monthly"])
        #expect(poolsSnapshot.windows.map(\.id.key) == ["cursor_models", "other_models"])
    }

    @Test("Cursor null removes one pool while omitted and malformed peers retain stale cache")
    func cursorPoolFailuresRetainOnlyLastGood() async throws {
        let initial = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let nullAndOmitted = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":null}}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let nullService = CLIUsageService(readers: [
            .cursor: SequencedProviderQuotaReader(results: [
                .success(initial),
                .success(nullAndOmitted),
            ]),
        ])

        _ = try await nullService.fetch()
        let nullSnapshot = try #require(
            try await nullService.fetch().first { $0.provider == .cursor }
        )

        let malformed = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":"bad","apiPercentUsed":35}}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let malformedService = CLIUsageService(readers: [
            .cursor: SequencedProviderQuotaReader(results: [
                .success(initial),
                .success(malformed),
            ]),
        ])
        _ = try await malformedService.fetch()
        let malformedSnapshot = try #require(
            try await malformedService.fetch().first { $0.provider == .cursor }
        )

        #expect(nullSnapshot.windows.map(\.id.key) == ["other_models"])
        #expect(nullSnapshot.windows.first?.freshness == .stale(
            reason: "Cursor other models quota was missing.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(malformedSnapshot.windows.first { $0.id.key == "cursor_models" }?.freshness == .stale(
            reason: "Cursor cursor models quota was malformed.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(malformedSnapshot.state == .available)
    }

    @Test("Disabling Grok on-demand removes its cached window")
    func grokOnDemandTransitionRemovesWindow() async throws {
        let enabled = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25,"onDemandUsed":{"val":10},"onDemandCap":{"val":100}},"onDemandEnabled":true}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let disabled = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":30},"onDemandEnabled":false}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [.success(enabled), .success(disabled)]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })

        #expect(snapshot.windows.map(\.id.key) == ["included"])
    }

    @Test("Omitted Grok on-demand availability retains cached quota as stale")
    func grokOnDemandOmissionRetainsStaleWindow() async throws {
        let enabled = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25,"onDemandUsed":{"val":10},"onDemandCap":{"val":100}},"onDemandEnabled":true}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let omitted = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":30}}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [.success(enabled), .success(omitted)]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })
        let onDemand = try #require(snapshot.windows.first { $0.id.key == "on_demand" })

        #expect(snapshot.state == .available)
        #expect(onDemand.remainingPercent == 90)
        #expect(onDemand.freshness == .stale(
            reason: "Grok on-demand availability was omitted.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("A first provider failure is unavailable and has no invented windows")
    func firstFailureIsUnavailable() async throws {
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [.failure(TestUsageError.offline)]),
        ])

        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })

        #expect(snapshot.state == .unavailable(reason: "Grok quota could not be refreshed."))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.fetchedAt == nil)
    }

    @Test("Grok failures expose only typed sanitized diagnostics", arguments: [
        (GrokACPUsageError.methodNotFound, "Grok CLI does not support _x.ai/billing."),
        (GrokACPUsageError.authenticationRequired, "Grok billing requires CLI authentication."),
        (GrokACPUsageError.timedOut, "Grok billing refresh timed out."),
    ])
    func grokFailureDiagnostics(
        error: GrokACPUsageError,
        expectedReason: String
    ) async throws {
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [.failure(error)]),
        ])

        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })

        #expect(snapshot.state == .unavailable(reason: expectedReason))
        #expect(!expectedReason.localizedCaseInsensitiveContains("payload"))
    }

    @Test("A typed provider failure preserves its sanitized reason on stale windows")
    func typedFailureReasonIsRetainedWhenStale() async throws {
        let service = CLIUsageService(readers: [
            .grok: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.grok, "included", "Weekly", 42))
                )),
                .failure(GrokACPUsageError.authenticationRequired),
            ]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(try await service.fetch().first { $0.provider == .grok })

        #expect(snapshot.state == .stale(reason: "Grok billing requires CLI authentication."))
        #expect(snapshot.windows.first?.freshness == .stale(
            reason: "Grok billing requires CLI authentication.",
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("expired Claude login preserves last-good quota with a sanitized action")
    func expiredClaudeLoginRetainsStaleUsage() async throws {
        let reason = "Claude login expired; run /login in Claude Code."
        let service = CLIUsageService(readers: [
            .claude: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.claude, "five_hour", "5 hr", 67))
                )),
                .failure(ProviderUsageError.authenticationRequired),
            ]),
        ])

        _ = try await service.fetch()
        let snapshot = try #require(
            try await service.fetch().first { $0.provider == .claude }
        )

        #expect(snapshot.state == .stale(reason: reason))
        #expect(snapshot.windows.first?.remainingPercent == 67)
        #expect(snapshot.windows.first?.freshness == .stale(
            reason: reason,
            lastSuccessfulAt: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test("Cancellation propagates and leaves the service cache unchanged")
    func cancellationDoesNotMutateServiceCache() async throws {
        let reader = SequencedProviderQuotaReader(results: [
            .success(observation(
                at: Date(timeIntervalSince1970: 100),
                .available(value(.codex, "primary", "5 hr", 61))
            )),
            .failure(CancellationError()),
            .failure(TestUsageError.offline),
        ])
        let service = CLIUsageService(readers: [.codex: reader])

        _ = try await service.fetch()
        await #expect(throws: CancellationError.self) {
            try await service.fetch()
        }
        let snapshot = try #require(try await service.fetch().first { $0.provider == .codex })

        #expect(snapshot.state == .stale(reason: "Codex quota could not be refreshed."))
        #expect(snapshot.windows.first?.remainingPercent == 61)
        #expect(snapshot.windows.first?.lastSuccessfulAt == Date(timeIntervalSince1970: 100))
    }

    @Test("Service clamps provider percentages and preserves reset metadata")
    func serviceClampsAndRetainsReset() async throws {
        let reset = Date(timeIntervalSince1970: 9_999)
        let service = CLIUsageService(readers: [
            .cursor: SequencedProviderQuotaReader(results: [
                .success(observation(
                    at: Date(timeIntervalSince1970: 100),
                    .available(value(.cursor, "low", "Low", -5, resetsAt: reset)),
                    .available(value(.cursor, "high", "High", 140, resetsAt: reset))
                )),
            ]),
        ])

        let snapshot = try #require(try await service.fetch().first { $0.provider == .cursor })

        #expect(snapshot.windows.map(\.remainingPercent) == [0, 100])
        #expect(snapshot.windows.map(\.resetsAt) == [reset, reset])
    }

    @MainActor
    @Test("Usage model keeps the scalar rail compatible during snapshot migration")
    func usageModelProjectsSnapshots() async throws {
        let reader = StubCLIUsageReader(snapshots: [
            ProviderUsageSnapshot(
                provider: .codex,
                state: .available,
                windows: [ProviderUsageWindow(
                    value: value(.codex, "primary", "Weekly", 55),
                    freshness: .fresh,
                    lastSuccessfulAt: Date(timeIntervalSince1970: 100)
                )],
                fetchedAt: Date(timeIntervalSince1970: 100)
            ),
            ProviderUsageSnapshot(
                provider: .claude,
                state: .unavailable(reason: "Claude quota is unavailable."),
                windows: [],
                fetchedAt: nil
            ),
        ])
        let model = CLIUsageModel(reader: reader)

        try await model.start()

        #expect(model.entries.map(\.kind) == [.codex, .claude, .grok, .cursor])
        #expect(model.entries[0].state == .available(remainingPercent: 55))
        #expect(model.entries[1].state == .unavailable(reason: "Claude quota is unavailable."))
        #expect(await reader.callCount == 1)
    }

    @MainActor
    @Test("Usage model projects provider loading, unavailable, stale, and partial-available states")
    func usageModelProjectsEverySnapshotState() async throws {
        let lastGoodAt = Date(timeIntervalSince1970: 100)
        let staleReason = "Grok quota could not be refreshed."
        let reader = StubCLIUsageReader(snapshots: [
            ProviderUsageSnapshot(
                provider: .codex,
                state: .loading,
                windows: [],
                fetchedAt: nil
            ),
            ProviderUsageSnapshot(
                provider: .claude,
                state: .unavailable(reason: "Claude quota is unavailable."),
                windows: [],
                fetchedAt: nil
            ),
            ProviderUsageSnapshot(
                provider: .grok,
                state: .stale(reason: staleReason),
                windows: [ProviderUsageWindow(
                    value: value(.grok, "included", "Weekly", 42),
                    freshness: .stale(reason: staleReason, lastSuccessfulAt: lastGoodAt),
                    lastSuccessfulAt: lastGoodAt
                )],
                fetchedAt: lastGoodAt
            ),
            ProviderUsageSnapshot(
                provider: .cursor,
                state: .available,
                windows: [
                    ProviderUsageWindow(
                        value: value(.cursor, "cursor_models", "Cursor Models", 70),
                        freshness: .fresh,
                        lastSuccessfulAt: Date(timeIntervalSince1970: 200)
                    ),
                    ProviderUsageWindow(
                        value: value(.cursor, "other_models", "Other Models", 20),
                        freshness: .stale(reason: "Peer malformed.", lastSuccessfulAt: lastGoodAt),
                        lastSuccessfulAt: lastGoodAt
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 200)
            ),
        ])
        let model = CLIUsageModel(reader: reader)

        try await model.start()

        #expect(model.entries.map(\.state) == [
            .loading,
            .unavailable(reason: "Claude quota is unavailable."),
            .stale(remainingPercent: 42, reason: staleReason),
            .available(remainingPercent: 20),
        ])
    }

    @MainActor
    @Test("Usage model permits a manual refresh after the initial snapshot")
    func usageModelRefreshes() async throws {
        let reader = StubCLIUsageReader(snapshots: [])
        let model = CLIUsageModel(reader: reader)

        try await model.start()
        _ = try await model.refresh()

        #expect(await reader.callCount == 2)
    }

    @MainActor
    @Test("Usage model leaves entries untouched when refresh is cancelled")
    func usageModelCancellationPreservesEntries() async throws {
        let snapshot = ProviderUsageSnapshot(
            provider: .codex,
            state: .available,
            windows: [ProviderUsageWindow(
                value: value(.codex, "primary", "5 hr", 61),
                freshness: .fresh,
                lastSuccessfulAt: Date(timeIntervalSince1970: 100)
            )],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let reader = SequencedCLIUsageReader(results: [
            .success([snapshot]),
            .failure(CancellationError()),
        ])
        let model = CLIUsageModel(reader: reader)
        try await model.start()
        let before = model.entries

        await #expect(throws: CancellationError.self) {
            try await model.refresh()
        }

        #expect(model.entries == before)
        #expect(model.isRefreshing == false)
    }

    @Test("Selected refresh reads only eligible providers")
    func selectedRefreshReadsOnlyEligibleProviders() async throws {
        let codex = SequencedProviderQuotaReader(results: [
            .success(observation(
                at: Date(timeIntervalSince1970: 100),
                .available(value(.codex, "primary", "5 hr", 75))
            )),
        ])
        let claude = SequencedProviderQuotaReader(results: [
            .success(observation(
                at: Date(timeIntervalSince1970: 100),
                .available(value(.claude, "five_hour", "5 hr", 65))
            )),
        ])
        let service = CLIUsageService(readers: [.codex: codex, .claude: claude])

        let snapshots = try await service.fetch(providers: [.codex])

        #expect(snapshots.map(\.provider) == [.codex])
        #expect(await codex.callCount == 1)
        #expect(await claude.callCount == 0)
    }

    @MainActor
    @Test("Usage model merges selected snapshots and reports provider outcomes")
    func modelMergesSelectedProviderRefresh() async throws {
        let codex = ProviderUsageSnapshot(
            provider: .codex,
            state: .available,
            windows: [ProviderUsageWindow(
                value: value(.codex, "primary", "5 hr", 75),
                freshness: .fresh,
                lastSuccessfulAt: Date(timeIntervalSince1970: 100)
            )],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let reader = SelectedCLIUsageReader(snapshots: [.codex: codex])
        let model = CLIUsageModel(reader: reader)

        let outcome = try await model.refresh(providers: [.codex, .claude])

        #expect(model.snapshots.first { $0.provider == .codex } == codex)
        #expect(model.snapshots.first { $0.provider == .claude }?.state == .unavailable(
            reason: "Account quota is not exposed by this CLI."
        ))
        #expect(outcome.succeeded == [.codex])
        #expect(outcome.failed == [.claude])
        #expect(await reader.requestedProviders == [[.codex, .claude]])
    }
}

private enum TestUsageError: Error {
    case offline
}

private actor SequencedProviderQuotaReader: ProviderQuotaReading {
    private var results: [Result<ProviderUsageObservation, Error>]
    private(set) var callCount = 0

    init(results: [Result<ProviderUsageObservation, Error>]) {
        self.results = results
    }

    func fetchObservation() async throws -> ProviderUsageObservation {
        callCount += 1
        guard !results.isEmpty else { throw TestUsageError.offline }
        return try results.removeFirst().get()
    }
}

private actor SelectedCLIUsageReader: CLIUsageReading {
    let snapshots: [AgentKind: ProviderUsageSnapshot]
    private(set) var requestedProviders: [Set<AgentKind>] = []

    init(snapshots: [AgentKind: ProviderUsageSnapshot]) {
        self.snapshots = snapshots
    }

    func fetch() async throws -> [ProviderUsageSnapshot] {
        Array(snapshots.values)
    }

    func fetch(providers: Set<AgentKind>) async throws -> [ProviderUsageSnapshot] {
        requestedProviders.append(providers)
        return providers.compactMap { snapshots[$0] }
    }
}

private actor StubCLIUsageReader: CLIUsageReading {
    private let snapshots: [ProviderUsageSnapshot]
    private(set) var callCount = 0

    init(snapshots: [ProviderUsageSnapshot]) {
        self.snapshots = snapshots
    }

    func fetch() async throws -> [ProviderUsageSnapshot] {
        callCount += 1
        return snapshots
    }
}

private actor SequencedCLIUsageReader: CLIUsageReading {
    private var results: [Result<[ProviderUsageSnapshot], Error>]

    init(results: [Result<[ProviderUsageSnapshot], Error>]) {
        self.results = results
    }

    func fetch() async throws -> [ProviderUsageSnapshot] {
        guard !results.isEmpty else { throw TestUsageError.offline }
        return try results.removeFirst().get()
    }
}

private func observation(
    at fetchedAt: Date,
    _ windows: ProviderUsageWindowObservation...
) -> ProviderUsageObservation {
    ProviderUsageObservation(windows: windows, fetchedAt: fetchedAt)
}

private func value(
    _ provider: AgentKind,
    _ key: String,
    _ label: String,
    _ remainingPercent: Int,
    resetsAt: Date? = nil
) -> ProviderUsageWindowValue {
    ProviderUsageWindowValue(
        id: ProviderUsageWindowID(provider: provider, key: key),
        label: label,
        remainingPercent: remainingPercent,
        resetsAt: resetsAt
    )
}
