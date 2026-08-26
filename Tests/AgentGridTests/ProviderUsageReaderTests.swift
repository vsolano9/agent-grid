import Foundation
import Darwin
import Testing
@testable import AgentGrid

@Suite(.serialized)
struct ProviderUsageReaderTests {
    @Test("Grok production billing timeout is fifteen seconds")
    func grokProductionTimeout() {
        #expect(GrokUsageReader.defaultTimeout == .seconds(15))
    }

    @Test(
        "shared provider date parser accepts fractional and nonfractional ISO-8601 forms",
        arguments: [
            "2026-08-25T07:07:27.291497+00:00",
            "2026-08-25T07:07:27.291497Z",
            "2026-08-25T07:07:27+00:00",
            "2026-08-25T07:07:27Z",
        ]
    )
    func providerDatesAcceptFractionalSeconds(value: String) throws {
        let parsed = try #require(ProviderUsageJSON.iso8601Date(value))
        let expectedFraction = value.contains(".291497") ? 0.291497 : 0

        #expect(abs(parsed.timeIntervalSince1970 - (1_787_641_647 + expectedFraction)) < 0.001)
    }

    @Test(
        "shared provider number parser accepts JSON zero and one numerics",
        arguments: ["0", "1", "0.0", "1.0"]
    )
    func providerNumbersAcceptZeroAndOne(value: String) throws {
        let data = Data("{\"value\":\(value)}".utf8)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(ProviderUsageJSON.number(root["value"]) == Double(value))
    }

    @Test(
        "shared provider number parser rejects JSON booleans",
        arguments: ["true", "false"]
    )
    func providerNumbersRejectBooleans(value: String) throws {
        let data = Data("{\"value\":\(value)}".utf8)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(ProviderUsageJSON.number(root["value"]) == nil)
    }

    @Test("Claude live shape accepts zero utilization and a fractional reset")
    func claudeAcceptsZeroUtilizationAndFractionalReset() throws {
        let payload = Data(#"{"five_hour":{"utilization":0,"resets_at":"2026-08-25T07:07:27.291497+00:00"},"seven_day":null}"#.utf8)

        let observation = try ClaudeUsageParser.parseObservation(from: payload, fetchedAt: .distantPast)
        let first = try #require(observation.windows.first)
        let window = try #require(availableValue(first))

        #expect(window.remainingPercent == 100)
        #expect(abs(try #require(window.resetsAt).timeIntervalSince1970 - 1_787_641_647.291497) < 0.001)
    }

    @Test("Cursor live shape accepts zero and one usage with a fractional billing reset")
    func cursorAcceptsLowUsageAndFractionalReset() throws {
        let payload = Data(#"{"billingCycleEnd":"2026-08-25T07:07:27.291497Z","individualUsage":{"plan":{"autoPercentUsed":0,"apiPercentUsed":1}}}"#.utf8)

        let observation = try CursorUsageParser.parseObservation(from: payload, fetchedAt: .distantPast)
        let windows = observation.windows.compactMap(availableValue)

        #expect(windows.map(\.remainingPercent) == [100, 99])
        #expect(windows.allSatisfy { window in
            guard let reset = window.resetsAt else { return false }
            return abs(reset.timeIntervalSince1970 - 1_787_641_647.291497) < 0.001
        })
    }

    @Test("Codex preserves primary and secondary windows with resets")
    func codexPreservesWindowsAndResets() throws {
        let payload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1787680800},"secondary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1788285600}}}}"#

        let observation = try CodexUsageResponseParser.parseObservation(
            payload,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(observation.windows == [
            .available(window(.codex, "primary", "5 hr", 80, reset: 1_787_680_800)),
            .available(window(.codex, "secondary", "Weekly", 35, reset: 1_788_285_600)),
        ])
    }

    @Test("Codex removes null windows and isolates malformed peers")
    func codexNullAndMalformedWindows() throws {
        let nullPayload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1787680800},"secondary":null}}}"#
        let partialPayload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":"bad","windowDurationMins":300},"secondary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1788285600}}}}"#

        let removed = try CodexUsageResponseParser.parseObservation(nullPayload, fetchedAt: .distantPast)
        let partial = try CodexUsageResponseParser.parseObservation(partialPayload, fetchedAt: .distantPast)

        #expect(removed.windows.last == .removed(ProviderUsageWindowID(provider: .codex, key: "secondary")))
        #expect(partial.windows.first == .failed(
            id: ProviderUsageWindowID(provider: .codex, key: "primary"),
            reason: "Codex primary quota was malformed."
        ))
        #expect(partial.windows.last == .available(
            window(.codex, "secondary", "Weekly", 35, reset: 1_788_285_600)
        ))
    }

    @Test("Codex emits failures for omitted fixed windows and malformed resets")
    func codexOmissionAndMalformedReset() throws {
        let payload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"resetsAt":"not-a-number"}}}}"#

        let observation = try CodexUsageResponseParser.parseObservation(payload, fetchedAt: .distantPast)

        #expect(observation.windows == [
            .failed(
                id: ProviderUsageWindowID(provider: .codex, key: "primary"),
                reason: "Codex primary quota was malformed."
            ),
            .failed(
                id: ProviderUsageWindowID(provider: .codex, key: "secondary"),
                reason: "Codex secondary quota was missing."
            ),
        ])
    }

    @Test("Codex fails malformed present durations but permits an absent duration label fallback")
    func codexDurationPresenceSemantics() throws {
        let payload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":"bad"},"secondary":{"usedPercent":65}}}}"#

        let observation = try CodexUsageResponseParser.parseObservation(
            payload,
            fetchedAt: .distantPast
        )

        #expect(observation.windows == [
            .failed(
                id: ProviderUsageWindowID(provider: .codex, key: "primary"),
                reason: "Codex primary quota was malformed."
            ),
            .available(window(.codex, "secondary", "Secondary", 35)),
        ])
    }

    @Test(
        "Codex rejects non-representable, fractional, non-positive numeric durations",
        arguments: ["1e300", "300.5", "-300", "0"]
    )
    func codexRejectsInvalidNumericDurations(rawDuration: String) throws {
        let payload = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":\#(rawDuration)},"secondary":null}}}"#

        let observation = try CodexUsageResponseParser.parseObservation(
            payload,
            fetchedAt: .distantPast
        )

        #expect(observation.windows.first == .failed(
            id: ProviderUsageWindowID(provider: .codex, key: "primary"),
            reason: "Codex primary quota was malformed."
        ))
    }

    @Test("Claude preserves account and named model windows with independent resets")
    func claudePreservesAllWindows() throws {
        let payload = Data(#"""
        {
          "five_hour":{"utilization":2.2,"resets_at":"2026-08-25T18:00:00Z"},
          "seven_day":{"utilization":74.6,"resets_at":"2026-08-31T18:00:00Z"},
          "seven_day_opus":{"utilization":19,"resets_at":"2026-08-30T18:00:00Z"},
          "limits":[
            {"name":"sonnet","percent":81.2,"is_active":true,"resets_at":"2026-08-29T18:00:00Z"},
            {"name":"inactive","percent":99,"is_active":false}
          ]
        }
        """#.utf8)

        let observation = try ClaudeUsageParser.parseObservation(
            from: payload,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(observation.windows.compactMap(availableValue).map(\.id.key) == [
            "five_hour", "seven_day", "seven_day_opus", "limit.sonnet",
        ])
        #expect(observation.windows.compactMap(availableValue).map(\.remainingPercent) == [98, 25, 81, 19])
        #expect(observation.windows.compactMap(availableValue).allSatisfy { $0.resetsAt != nil })
        #expect(observation.windows.contains(.removed(
            ProviderUsageWindowID(provider: .claude, key: "limit.inactive")
        )))
    }

    @Test("Claude CLI usage maps account and named model windows with reset suffixes")
    func claudeCLIUsageMapsAllWindows() throws {
        let payload = Data(#"""
        You are currently using your subscription to power your Claude Code usage

        Current session: 0% used · resets Aug 26 at 3:40pm (Europe/Berlin)
        Current week (all models): 0% used · resets Sep 1 at 9pm (Europe/Berlin)
        Current week (Fable): 0% used

        Last 24h · 195 requests · 18 sessions
          Top skills: /i-have-adhd 11%
        """#.utf8)

        let observation = try ClaudeUsageParser.parseObservation(
            from: payload,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(observation.windows.compactMap(availableValue) == [
            window(.claude, "five_hour", "5 hr", 100),
            window(.claude, "seven_day", "Weekly", 100),
            window(.claude, "seven_day_fable", "Fable", 100),
        ])
    }

    @Test("live Claude reader prefers the installed CLI usage surface")
    func liveClaudeReaderPrefersCLIUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentgrid-claude-cli-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".local/bin/claude")
        let configDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let script = """
        #!/bin/sh
        [ "$1" = "/usage" ] || exit 64
        [ "$CLAUDE_CONFIG_DIR" = "\(configDirectory.path)" ] || exit 65
        printf '%s\n' \
          'Current session: 12% used' \
          'Current week (all models): 34% used' \
          'Current week (Fable): 56% used'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        try Data(#"{"claudeAiOauth":{"accessToken":"invalid-test-token","expiresAt":9999999999999}}"#.utf8)
            .write(to: configDirectory.appendingPathComponent(".credentials.json"))
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = nil
        let service = CLIUsageService.live(environment: environment, homeDirectory: root)

        let snapshot = try #require(
            try await service.fetch(providers: [.claude]).first
        )

        #expect(snapshot.state == .available)
        #expect(snapshot.windows.map(\.remainingPercent) == [88, 66, 44])
    }

    @Test("Claude removes null windows and reports a malformed model beside valid account windows")
    func claudeNullAndMalformedWindows() throws {
        let payload = Data(#"""
        {
          "five_hour":{"utilization":10},
          "seven_day":null,
          "seven_day_opus":{"utilization":"bad"}
        }
        """#.utf8)

        let observation = try ClaudeUsageParser.parseObservation(from: payload, fetchedAt: .distantPast)

        #expect(observation.windows.first == .available(window(.claude, "five_hour", "5 hr", 90)))
        #expect(observation.windows.contains(.removed(
            ProviderUsageWindowID(provider: .claude, key: "seven_day")
        )))
        #expect(observation.windows.contains(.failed(
            id: ProviderUsageWindowID(provider: .claude, key: "seven_day_opus"),
            reason: "Claude seven_day_opus quota was malformed."
        )))
    }

    @Test("Claude emits fixed-window failures for omission and malformed reset")
    func claudeOmissionAndMalformedReset() throws {
        let payload = Data(#"{"five_hour":{"utilization":10,"resets_at":"invalid"}}"#.utf8)

        let observation = try ClaudeUsageParser.parseObservation(from: payload, fetchedAt: .distantPast)

        #expect(observation.windows == [
            .failed(
                id: ProviderUsageWindowID(provider: .claude, key: "five_hour"),
                reason: "Claude five_hour quota was malformed."
            ),
            .failed(
                id: ProviderUsageWindowID(provider: .claude, key: "seven_day"),
                reason: "Claude seven_day quota was missing."
            ),
        ])
    }

    @Test("Claude credential parser extracts the OAuth access token")
    func claudeCredentialParser() throws {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"claude-test-token","expiresAt":9999999999999}}"#.utf8)

        #expect(try ClaudeCredentialParser.accessToken(from: payload) == "claude-test-token")
    }

    @Test(
        "Claude credential parser rejects malformed explicit expiry",
        arguments: ["true", #""invalid""#]
    )
    func claudeCredentialParserRejectsMalformedExpiry(rawExpiry: String) {
        let payload = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"claude-test-token\",\"expiresAt\":\(rawExpiry)}}".utf8
        )

        #expect(throws: ProviderUsageError.authenticationRequired) {
            try ClaudeCredentialParser.accessToken(from: payload)
        }
    }

    @Test(
        "Claude credential parser keeps absent and null expiry compatible",
        arguments: ["", ",\"expiresAt\":null"]
    )
    func claudeCredentialParserAllowsAbsentOrNullExpiry(expiryField: String) throws {
        let payload = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"claude-test-token\"\(expiryField)}}".utf8
        )

        #expect(
            try ClaudeCredentialParser.accessToken(
                from: payload,
                now: Date(timeIntervalSince1970: 2)
            ) == "claude-test-token"
        )
    }

    @Test("Claude credential expiry boundary is fail closed")
    func claudeCredentialParserRejectsExpiryAtCurrentInstant() {
        let payload = Data(
            #"{"claudeAiOauth":{"accessToken":"claude-test-token","expiresAt":2000}}"#.utf8
        )

        #expect(throws: ProviderUsageError.authenticationRequired) {
            try ClaudeCredentialParser.accessToken(
                from: payload,
                now: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test("expired Claude login skips the quota request")
    func expiredClaudeLoginSkipsTransport() async throws {
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"expired-secret","expiresAt":1000}}"#.utf8)
        let transport = RecordingHTTPTransport(
            data: Data(#"{"five_hour":{"utilization":12}}"#.utf8)
        )
        let store = ClaudeAccessTokenStore(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/tmp/agentgrid-claude-expired"),
            fileDataLoader: { _ in expired },
            fallbackAccessTokenLoader: { throw ProviderUsageError.missingCredentials }
        )
        let reader = ClaudeUsageReader(accessTokenLoader: store, transport: transport)

        await #expect(throws: ProviderUsageError.authenticationRequired) {
            try await reader.fetchObservation()
        }
        #expect(await transport.lastRequest == nil)
    }

    @Test("Claude usage 401 publishes one sanitized login action")
    func claudeUnauthorizedIsActionableAndSanitized() async throws {
        let accessToken = "claude-access-secret"
        let responseSecret = "provider-response-secret"
        let transport = RecordingHTTPTransport(
            data: Data("{\"error\":\"\(responseSecret)\"}".utf8),
            statusCode: 401
        )
        let reader = ClaudeUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: accessToken),
            transport: transport
        )
        let service = CLIUsageService(readers: [.claude: reader])

        let snapshot = try #require(
            try await service.fetch(providers: [.claude]).first
        )
        let expected = "Claude login expired; run /login in Claude Code."

        #expect(snapshot.state == .unavailable(reason: expected))
        #expect(snapshot.windows.isEmpty)
        #expect(!String(describing: snapshot.state).contains(accessToken))
        #expect(!String(describing: snapshot.state).contains(responseSecret))
        #expect(await transport.requestCount == 1)
    }

    @Test("unexpired Claude login still returns live quota windows")
    func validClaudeLoginReturnsUsage() async throws {
        let valid = Data(#"{"claudeAiOauth":{"accessToken":"valid-secret","expiresAt":9999999999999}}"#.utf8)
        let transport = RecordingHTTPTransport(
            data: Data(#"{"five_hour":{"utilization":12}}"#.utf8)
        )
        let store = ClaudeAccessTokenStore(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/tmp/agentgrid-claude-valid"),
            fileDataLoader: { _ in valid },
            fallbackAccessTokenLoader: { throw ProviderUsageError.missingCredentials }
        )
        let reader = ClaudeUsageReader(accessTokenLoader: store, transport: transport)

        let observation = try await reader.fetchObservation()

        #expect(observation.windows.first == .available(window(.claude, "five_hour", "5 hr", 88)))
        #expect(await transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer valid-secret")
    }

    @Test("Claude reader sends the required OAuth headers")
    func claudeRequest() async throws {
        let transport = RecordingHTTPTransport(
            data: Data(#"{"five_hour":{"utilization":12}}"#.utf8)
        )
        let reader = ClaudeUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: "claude-test-token"),
            transport: transport
        )

        let observation = try await reader.fetchObservation()
        #expect(observation.windows.first == .available(window(.claude, "five_hour", "5 hr", 88)))
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test("Grok ACP uses canonical initialize then billing and preserves quota windows")
    func grokCanonicalACPSequence() async throws {
        let fixture = try FakeGrokFixture(mode: "success")
        defer { fixture.cleanup() }
        let reader = GrokUsageReader(
            executable: fixture.executable,
            environment: fixture.environment,
            timeout: .seconds(2)
        )

        let observation = try await reader.fetchObservation()
        let records = try fixture.transcript()
        let methods = records.compactMap { $0["method"] as? String }
        let initialize = try #require(records.first { $0["method"] as? String == "initialize" })
        let billing = try #require(records.first { $0["method"] as? String == "_x.ai/billing" })

        #expect((records.first?["arguments"] as? [String]) == ["--no-auto-update", "agent", "stdio"])
        #expect(methods == ["initialize", "_x.ai/billing"])
        #expect((initialize["params"] as? [String: Any])?["protocolVersion"] as? Int == 1)
        #expect((billing["params"] as? [String: Any])?.isEmpty == true)
        #expect(!methods.contains("authenticate"))
        #expect(observation.windows == [
            .available(window(.grok, "included", "Weekly", 75, reset: 1_788_220_800)),
            .available(window(.grok, "on_demand", "On demand", 75, reset: 1_788_220_800)),
        ])
    }

    @Test(
        "Grok reader accepts fractional reset timestamps from billing",
        arguments: ["fractional_offset", "fractional_z"]
    )
    func grokAcceptsFractionalResetTimestamps(mode: String) async throws {
        let fixture = try FakeGrokFixture(mode: mode)
        defer { fixture.cleanup() }

        let observation = try await fixture.reader().fetchObservation()
        let first = try #require(observation.windows.first)
        let included = try #require(availableValue(first))

        #expect(included.id == ProviderUsageWindowID(provider: .grok, key: "included"))
        #expect(included.remainingPercent == 100)
        #expect(abs(try #require(included.resetsAt).timeIntervalSince1970 - 1_787_641_647.291497) < 0.001)
    }

    @Test("Grok ACP closes a successful persistent stdio child promptly")
    func grokSuccessTerminatesPersistentChild() async throws {
        let fixture = try FakeGrokFixture(mode: "success_persistent")
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let start = clock.now

        _ = try await fixture.reader(timeout: .seconds(10)).fetchObservation()

        #expect(start.duration(to: clock.now) < .seconds(1))
        let processID = try #require(fixture.processID())
        #expect(await processExited(processID))
    }

    @Test("Grok ACP omits disabled on-demand and supports deprecated monthly fields")
    func grokBillingFallbacks() async throws {
        let disabled = try FakeGrokFixture(mode: "no_on_demand")
        defer { disabled.cleanup() }
        let deprecated = try FakeGrokFixture(mode: "deprecated")
        defer { deprecated.cleanup() }

        let disabledObservation = try await disabled.reader().fetchObservation()
        let deprecatedObservation = try await deprecated.reader().fetchObservation()

        #expect(disabledObservation.windows.map(\.id.key) == ["included", "on_demand"])
        #expect(disabledObservation.windows.last == .removed(
            ProviderUsageWindowID(provider: .grok, key: "on_demand")
        ))
        #expect(deprecatedObservation.windows == [
            .available(window(.grok, "included", "Monthly", 75, reset: 1_788_220_800)),
            .removed(ProviderUsageWindowID(provider: .grok, key: "on_demand")),
        ])
    }

    @Test("Grok distinguishes omitted, null, false, and malformed on-demand flags")
    func grokOnDemandFlagPresenceSemantics() throws {
        let omitted = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25}}"#.utf8),
            fetchedAt: .distantPast
        )
        let explicitNull = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25},"onDemandEnabled":null}"#.utf8),
            fetchedAt: .distantPast
        )
        let explicitFalse = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25},"onDemandEnabled":false}"#.utf8),
            fetchedAt: .distantPast
        )
        let malformed = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25},"onDemandEnabled":"yes"}"#.utf8),
            fetchedAt: .distantPast
        )
        let id = ProviderUsageWindowID(provider: .grok, key: "on_demand")

        #expect(omitted.windows.last == .failed(
            id: id,
            reason: "Grok on-demand availability was omitted."
        ))
        #expect(explicitNull.windows.last == .removed(id))
        #expect(explicitFalse.windows.last == .removed(id))
        #expect(malformed.windows.last == .failed(
            id: id,
            reason: "Grok on-demand availability was malformed."
        ))
    }

    @Test("Grok ACP sanitizes method, auth, malformed, EOF, and stderr failures")
    func grokACPFailuresAreSanitized() async throws {
        for (mode, expected) in [
            ("method_error", GrokACPUsageError.methodNotFound),
            ("auth_error", .authenticationRequired),
            ("malformed", .invalidResponse),
            ("early_eof", .processEnded),
            ("stderr_error", .rpcFailure),
        ] {
            let fixture = try FakeGrokFixture(mode: mode)
            defer { fixture.cleanup() }
            await #expect(throws: expected) {
                try await fixture.reader().fetchObservation()
            }
        }
    }

    @Test("Grok ACP times out and terminates the child")
    func grokACPTimeoutTerminatesChild() async throws {
        let fixture = try FakeGrokFixture(mode: "timeout")
        defer { fixture.cleanup() }

        await #expect(throws: GrokACPUsageError.timedOut) {
            try await fixture.reader(timeout: .milliseconds(100)).fetchObservation()
        }
        let processID = try #require(fixture.processID())
        #expect(await processExited(processID))
    }

    @Test("Grok ACP escalates past a root that ignores SIGTERM")
    func grokACPNonCooperativeRootIsBounded() async throws {
        let fixture = try FakeGrokFixture(mode: "ignore_term_timeout")
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: GrokACPUsageError.timedOut) {
            try await fixture.reader(timeout: .milliseconds(100)).fetchObservation()
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
        let processID = try #require(fixture.processID())
        #expect(await processExited(processID))
    }

    @Test("Grok ACP kills a stderr-inheriting descendant after successful billing")
    func grokACPInheritedStderrDescendantIsBounded() async throws {
        let fixture = try FakeGrokFixture(mode: "inherited_stderr")
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let start = clock.now

        _ = try await fixture.reader(timeout: .seconds(10)).fetchObservation()

        #expect(start.duration(to: clock.now) < .seconds(1))
        let rootPID = try #require(fixture.processID())
        let childPID = try #require(fixture.childProcessID())
        #expect(await processExited(rootPID))
        #expect(await processExited(childPID))
    }

    @Test("Cancelling Grok ACP terminates the child")
    func grokACPCancellationTerminatesChild() async throws {
        let fixture = try FakeGrokFixture(mode: "timeout")
        defer { fixture.cleanup() }
        let task = Task { try await fixture.reader(timeout: .seconds(10)).fetchObservation() }
        let processID = try #require(await fixture.awaitProcessID())

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await processExited(processID))
    }

    @Test("Repeated Grok timeouts and cancellations release children and file descriptors")
    func grokRepeatedCleanup() async throws {
        let baseline = openFileDescriptorCount()
        let baselineTypes = openFileDescriptorTypeCounts()
        for iteration in 0..<8 {
            let fixture = try FakeGrokFixture(mode: "timeout")
            if iteration.isMultiple(of: 2) {
                await #expect(throws: GrokACPUsageError.timedOut) {
                    try await fixture.reader(timeout: .milliseconds(50)).fetchObservation()
                }
            } else {
                let task = Task {
                    try await fixture.reader(timeout: .seconds(10)).fetchObservation()
                }
                _ = try #require(await fixture.awaitProcessID())
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            let processID = try #require(fixture.processID())
            #expect(await processExited(processID))
            fixture.cleanup()
        }
        #expect(openFileDescriptorCount() <= baseline + 2)
        #expect(openFileDescriptorTypeCounts().pipes <= baselineTypes.pipes)
    }

    @Test("concurrent Grok cleanup callers share one bounded nonblocking reap")
    func grokConcurrentBoundedCleanup() async throws {
        let fixture = try FakeGrokFixture(mode: "ignore_term_timeout")
        defer { fixture.cleanup() }
        let reapProbe = DelayedGrokReapProbe(delayedPollCount: 20)
        let process = try GrokACPProcess.spawn(
            executable: fixture.executable,
            arguments: ["--no-auto-update", "agent", "stdio"],
            environment: fixture.environment,
            reapPoll: reapProbe.poll(processID:)
        )
        defer { process.closeParentReadPipes() }
        let clock = ContinuousClock()
        let start = clock.now

        async let first: Void = process.terminateAndReap(didTimeOut: true)
        async let second: Void = process.terminateAndReap()
        _ = await (first, second)

        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(reapProbe.pollCount >= 20)
        let processID = try #require(await fixture.awaitProcessID())
        #expect(await processExited(processID))
    }

    @Test("Grok fetch returns at its cleanup bound and later reaps without another caller")
    func grokFetchHandsOffDelayedReaping() async throws {
        let fixture = try FakeGrokFixture(mode: "ignore_term_timeout")
        defer { fixture.cleanup() }
        let reapProbe = DelayedGrokReapProbe(delayedPollCount: 90)
        let client = GrokACPUsageClient(
            executable: fixture.executable,
            environment: fixture.environment,
            timeout: .milliseconds(50),
            reapPoll: reapProbe.poll(processID:)
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: GrokACPUsageError.timedOut) {
            try await client.fetchObservation()
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(await reapProbe.awaitPollCount(91))
        let processID = try #require(await fixture.awaitProcessID())
        #expect(await processExited(processID))
    }

    @Test("Cursor builds the authenticated cookie from its JWT subject")
    func cursorCookie() throws {
        let token = makeJWT(payload: #"{"sub":"auth0|user_123"}"#)

        #expect(try CursorAuthTokenParser.cookieHeader(accessToken: token) ==
            "WorkosCursorSessionToken=user_123%3A%3A\(token)")
    }

    @Test("Cursor preserves its two monthly model pools and cycle end")
    func cursorPreservesMonthlyPools() throws {
        let payload = Data(#"{"billingCycleEnd":"2026-09-01T00:00:00Z","individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8)

        let observation = try CursorUsageParser.parseObservation(from: payload, fetchedAt: .distantPast)

        #expect(observation.windows == [
            .removed(ProviderUsageWindowID(provider: .cursor, key: "monthly")),
            .available(window(.cursor, "cursor_models", "Cursor Models", 90, reset: 1_788_220_800)),
            .available(window(.cursor, "other_models", "Other Models", 70, reset: 1_788_220_800)),
        ])
    }

    @Test("Cursor uses a legacy composite fallback without inventing missing pools")
    func cursorLegacyAndMissingFieldBehavior() throws {
        let legacy = Data(#"{"individualUsage":{"plan":{"totalPercentUsed":17.3214,"used":99,"limit":100}}}"#.utf8)
        let onePool = Data(#"{"individualUsage":{"plan":{"autoPercentUsed":10}}}"#.utf8)

        let legacyObservation = try CursorUsageParser.parseObservation(from: legacy, fetchedAt: .distantPast)
        let onePoolObservation = try CursorUsageParser.parseObservation(from: onePool, fetchedAt: .distantPast)

        #expect(legacyObservation.windows == [
            .removed(ProviderUsageWindowID(provider: .cursor, key: "cursor_models")),
            .removed(ProviderUsageWindowID(provider: .cursor, key: "other_models")),
            .available(window(.cursor, "monthly", "Monthly", 83)),
        ])
        #expect(onePoolObservation.windows == [
            .removed(ProviderUsageWindowID(provider: .cursor, key: "monthly")),
            .available(window(.cursor, "cursor_models", "Cursor Models", 90)),
            .failed(
                id: ProviderUsageWindowID(provider: .cursor, key: "other_models"),
                reason: "Cursor other models quota was missing."
            ),
        ])
    }

    @Test("Cursor distinguishes explicit-null, omitted, and malformed model pools")
    func cursorPoolPresenceSemantics() throws {
        let observation = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":null}}}"#.utf8),
            fetchedAt: .distantPast
        )

        #expect(observation.windows == [
            .removed(ProviderUsageWindowID(provider: .cursor, key: "monthly")),
            .removed(ProviderUsageWindowID(provider: .cursor, key: "cursor_models")),
            .failed(
                id: ProviderUsageWindowID(provider: .cursor, key: "other_models"),
                reason: "Cursor other models quota was missing."
            ),
        ])
    }

    @Test("Cursor pooled fallback requires an explicit applicability flag")
    func cursorPooledFallbackApplicability() throws {
        let applicable = Data(#"{"teamUsage":{"pooled":{"enabled":true,"used":20,"limit":100}}}"#.utf8)
        let nonApplicable = Data(#"{"teamUsage":{"pooled":{"used":20,"limit":100}}}"#.utf8)

        let observation = try CursorUsageParser.parseObservation(from: applicable, fetchedAt: .distantPast)
        #expect(observation.windows.last == .available(window(.cursor, "monthly", "Monthly", 80)))
        #expect(throws: ProviderUsageError.missingQuota) {
            try CursorUsageParser.parseObservation(from: nonApplicable, fetchedAt: .distantPast)
        }
    }

    @Test("Provider parsers reject booleans as quota numbers")
    func parsersRejectBooleanNumbers() throws {
        let codex = try CodexUsageResponseParser.parseObservation(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":true},"secondary":null}}}"#,
            fetchedAt: .distantPast
        )
        let claude = try ClaudeUsageParser.parseObservation(
            from: Data(#"{"five_hour":{"utilization":true},"seven_day":null}"#.utf8),
            fetchedAt: .distantPast
        )
        let cursor = try CursorUsageParser.parseObservation(
            from: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":true}}}"#.utf8),
            fetchedAt: .distantPast
        )
        let grok = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":true},"onDemandEnabled":false}"#.utf8),
            fetchedAt: .distantPast
        )

        #expect(codex.windows.first?.isFailed == true)
        #expect(claude.windows.first?.isFailed == true)
        #expect(cursor.windows.contains { $0.id.key == "cursor_models" && $0.isFailed })
        #expect(grok.windows.first?.isFailed == true)
    }

    @Test("Malformed provider resets fail the known window instead of publishing fresh nil")
    func malformedResetsFailWindows() throws {
        let cursor = try CursorUsageParser.parseObservation(
            from: Data(#"{"billingCycleEnd":"invalid","individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8),
            fetchedAt: .distantPast
        )
        let grok = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25,"currentPeriod":{"end":"invalid"}},"onDemandEnabled":false}"#.utf8),
            fetchedAt: .distantPast
        )
        let grokNonStringReset = try GrokUsageParser.parseObservation(
            from: Data(#"{"config":{"creditUsagePercent":25,"currentPeriod":{"end":true}},"onDemandEnabled":false}"#.utf8),
            fetchedAt: .distantPast
        )

        #expect(cursor.windows.filter(\.isFailed).count == 2)
        #expect(grok.windows.first?.isFailed == true)
        #expect(grokNonStringReset.windows.first?.isFailed == true)
    }

    @Test("Cursor reader sends its local app session cookie")
    func cursorRequest() async throws {
        let token = makeJWT(payload: #"{"sub":"workos|cursor-user"}"#)
        let transport = RecordingHTTPTransport(
            data: Data(#"{"individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":30}}}"#.utf8)
        )
        let reader = CursorUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: token),
            transport: transport
        )

        let observation = try await reader.fetchObservation()
        #expect(observation.windows.compactMap(availableValue).map(\.remainingPercent) == [90, 70])
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "https://cursor.com/api/usage-summary")
        #expect(request.value(forHTTPHeaderField: "Cookie") ==
            "WorkosCursorSessionToken=cursor-user%3A%3A\(token)")
    }

    @Test("Provider readers reject non-success HTTP responses")
    func providerRejectsHTTPError() async {
        let reader = ClaudeUsageReader(
            accessTokenLoader: StaticAccessTokenLoader(token: "claude-test-token"),
            transport: RecordingHTTPTransport(data: Data(), statusCode: 503)
        )

        await #expect(throws: ProviderUsageError.httpStatus(503)) {
            try await reader.fetchObservation()
        }
    }

    @Test("cancelling provider HTTP transport cancels its URLSession data task")
    func providerHTTPCancellationStopsDataTask() async throws {
        let probe = HTTPURLProtocolProbe()
        HangingProviderURLProtocol.install(probe)
        defer { HangingProviderURLProtocol.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProviderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionProviderUsageHTTPTransport(session: session)
        let request = URLRequest(url: URL(string: "https://provider.test/usage")!)
        let task = Task { try await transport.response(for: request) }

        await probe.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await probe.waitUntilStopped()
    }

    private func makeJWT(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}

private final class FakeGrokFixture: @unchecked Sendable {
    let executable: URL
    let environment: [String: String]
    private let directory: URL
    private let transcriptURL: URL
    private let pidURL: URL
    private let childPIDURL: URL

    init(mode: String) throws {
        let productDirectory = Bundle(for: BundleLocator.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        executable = productDirectory.appendingPathComponent("FakeGrokACP")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProviderUsageError.invalidResponse
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentGrid-GrokACP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcriptURL = directory.appendingPathComponent("transcript.jsonl")
        pidURL = directory.appendingPathComponent("pid")
        childPIDURL = directory.appendingPathComponent("child-pid")
        var values = ProcessInfo.processInfo.environment
        values["FAKE_GROK_MODE"] = mode
        values["FAKE_GROK_TRANSCRIPT"] = transcriptURL.path
        values["FAKE_GROK_PID"] = pidURL.path
        values["FAKE_GROK_CHILD_PID"] = childPIDURL.path
        environment = values
    }

    func reader(timeout: Duration = .seconds(2)) -> GrokUsageReader {
        GrokUsageReader(executable: executable, environment: environment, timeout: timeout)
    }

    func transcript() throws -> [[String: Any]] {
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let data = Data(line.utf8)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    func processID() -> pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let value = Int32(text) else { return nil }
        return value
    }

    func childProcessID() -> pid_t? {
        guard let text = try? String(contentsOf: childPIDURL, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return value
    }

    func awaitProcessID() async -> pid_t? {
        for _ in 0..<100 {
            if let processID = processID() { return processID }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class BundleLocator {}

private final class DelayedGrokReapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delayedPollCount: Int
    private var polls = 0

    init(delayedPollCount: Int) {
        self.delayedPollCount = delayedPollCount
    }

    var pollCount: Int { lock.withLock { polls } }

    func poll(processID: pid_t) -> GrokACPReapResult {
        let shouldDelay = lock.withLock { () -> Bool in
            polls += 1
            return polls <= delayedPollCount
        }
        return shouldDelay ? .running : .poll(processID: processID)
    }

    func awaitPollCount(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if pollCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private func processExited(_ processID: pid_t) async -> Bool {
    for _ in 0..<100 {
        if Darwin.kill(processID, 0) == -1 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

private func openFileDescriptorTypeCounts() -> (pipes: Int, sockets: Int, files: Int) {
    var result = (pipes: 0, sockets: 0, files: 0)
    let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    for descriptor in descriptors.compactMap(Int32.init) {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { continue }
        switch status.st_mode & S_IFMT {
        case S_IFIFO:
            result.pipes += 1
        case S_IFSOCK:
            result.sockets += 1
        default:
            result.files += 1
        }
    }
    return result
}

private func window(
    _ provider: AgentKind,
    _ key: String,
    _ label: String,
    _ remainingPercent: Int,
    reset: TimeInterval? = nil
) -> ProviderUsageWindowValue {
    ProviderUsageWindowValue(
        id: ProviderUsageWindowID(provider: provider, key: key),
        label: label,
        remainingPercent: remainingPercent,
        resetsAt: reset.map(Date.init(timeIntervalSince1970:))
    )
}

private func availableValue(_ item: ProviderUsageWindowObservation) -> ProviderUsageWindowValue? {
    guard case .available(let value) = item else { return nil }
    return value
}

private extension ProviderUsageWindowObservation {
    var isFailed: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

private struct StaticAccessTokenLoader: ProviderAccessTokenLoading {
    let token: String

    func loadAccessToken() async throws -> String { token }
}

private actor RecordingHTTPTransport: ProviderUsageHTTPTransport {
    let data: Data
    let statusCode: Int
    private(set) var lastRequest: URLRequest?
    private(set) var requestCount = 0

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func response(for request: URLRequest) async throws -> ProviderUsageHTTPResponse {
        requestCount += 1
        lastRequest = request
        return ProviderUsageHTTPResponse(data: data, statusCode: statusCode)
    }
}

private final class HTTPURLProtocolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    var didStart: Bool { lock.withLock { started } }
    var didStop: Bool { lock.withLock { stopped } }

    func waitUntilStarted() async {
        await wait(for: \.started, storingIn: \.startWaiters)
    }

    func waitUntilStopped() async {
        await wait(for: \.stopped, storingIn: \.stopWaiters)
    }

    func markStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            started = true
            defer { startWaiters = [] }
            return startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func markStopped() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stopped = true
            defer { stopWaiters = [] }
            return stopWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private func wait(
        for state: ReferenceWritableKeyPath<HTTPURLProtocolProbe, Bool>,
        storingIn waiters: ReferenceWritableKeyPath<
            HTTPURLProtocolProbe,
            [CheckedContinuation<Void, Never>]
        >
    ) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if self[keyPath: state] { return true }
                self[keyPath: waiters].append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

private final class HangingProviderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var probe: HTTPURLProtocolProbe?

    static func install(_ probe: HTTPURLProtocolProbe?) {
        lock.withLock { self.probe = probe }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.probe }?.markStarted() }
    override func stopLoading() { Self.lock.withLock { Self.probe }?.markStopped() }
}
