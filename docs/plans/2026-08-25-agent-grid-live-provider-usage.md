# AgentGrid Live Provider Usage Implementation Plan

> **For the executor:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Replace placeholder quota states with real, privacy-preserving Codex, Claude, Grok, and Cursor percentages while omitting Hermes from the rail.

**Architecture:** A single actor coordinates four provider readers, normalizes their results, and retains last-good values in memory. Provider-specific modules own local credential discovery, request construction, response parsing, and actionable errors behind a common quota-reading protocol.

**Tech Stack:** Swift 6, Foundation concurrency and URLSession, macOS Security, SQLite3, SwiftUI, Swift Testing, XcodeGen.

---

## Execution constraints

- Work only in `feat/live-provider-usage` until merged-main verification.
- Preserve all terminal selection, CLI maintenance, alias repair, and Hermes launch behavior.
- Never print, persist, fixture, or commit a real token, cookie, credential payload, or raw authenticated response.
- Use the existing visual rail; this is a data and state change, not a redesign.
- Keep provider requests cancellable and independently bounded.
- Commit and push only after focused tests, the full suite, Debug and Release builds, live reads, visual inspection, and secret review pass.

## Task 1: Establish the provider contract and four-entry rail

**Behavior seam:** `CLIUsageReading.fetch()` returns exactly Codex, Claude, Grok, and Cursor in the model's display order; Hermes is absent.

**Modify:**
- `Sources/AgentGrid/CLIUsageState.swift`
- `Sources/AgentGrid/CLIUsageReading.swift`
- `Sources/AgentGrid/CLIUsageModel.swift`
- `Sources/AgentGrid/CLIUsageSegment.swift`
- `Tests/AgentGridTests/CLIUsageTests.swift`

1. Add failing tests for the four-provider order and for preserving a successful reading as stale after a later provider failure.
2. Run the focused usage tests and confirm failures are caused by the current five-entry placeholder behavior.
3. Introduce the provider quota protocol, four-kind display contract, fresh/stale states, and coordinator cache.
4. Run the focused usage tests and the existing CLI maintenance tests.

## Task 2: Add Claude OAuth usage

**Behavior seam:** a synthetic Claude credential and OAuth payload produce the remaining percentage of the most constrained active window.

**Create:**
- `Sources/AgentGrid/ClaudeUsageReader.swift`
- `Sources/AgentGrid/ProviderUsageHTTPTransport.swift`

**Modify:**
- `Tests/AgentGridTests/CLIUsageTests.swift`

1. Add failing parser, header, missing-credential, malformed-response, and window-precedence tests.
2. Implement credentials-file parsing, Claude Code Keychain fallback, bounded HTTPS fetch, and response normalization.
3. Run focused tests and verify no token appears in output or errors.

## Task 3: Add Grok billing credits

**Behavior seam:** a synthetic Grok auth map and billing payload produce remaining credits, including the used/cap fallback.

**Create:**
- `Sources/AgentGrid/GrokUsageReader.swift`

**Modify:**
- `Tests/AgentGridTests/CLIUsageTests.swift`

1. Add failing preferred-entry, percent, used/cap, clamp, malformed, and request-header tests.
2. Implement read-only `auth.json` discovery, bounded HTTPS fetch, and parser.
3. Run focused tests and verify the credential file remains byte-identical.

## Task 4: Add Cursor plan allowance

**Behavior seam:** a synthetic Cursor SQLite database and usage-summary payload produce the dashboard-equivalent remaining percentage.

**Create:**
- `Sources/AgentGrid/CursorUsageReader.swift`

**Modify:**
- `project.yml`
- `Tests/AgentGridTests/CLIUsageTests.swift`

1. Add failing SQLite token, JWT cookie, percent-precedence, ratio-fallback, malformed-token, and unauthorized-response tests.
2. Link SQLite3 and implement read-only WAL-aware credential loading plus the bounded Cursor request.
3. Regenerate `AgentGrid.xcodeproj` and run the focused tests.

## Task 5: Integrate, document, and ship

**Modify:**
- `Sources/AgentGrid/CLIUsageReading.swift`
- `README.md`
- `CONTEXT-MAP.md`
- `THIRD_PARTY_NOTICES.md`
- `project.yml`
- generated Xcode project files

1. Wire the four live readers into `CLIUsageService.live()` and add MIT attribution.
2. Update user and owner documentation, bump the patch version/build, and regenerate the project.
3. Run focused provider tests, all 76+ tests, Debug build, Release build, project-generation drift, and secret scans.
4. Run live read-only probes through production reader code and confirm four real percentages without raw payload output.
5. Install the Release bundle, launch twice, manually inspect the four-segment rail and stale/unavailable behavior, and verify CLI maintenance still runs no updater when versions are current.
6. Review every changed file and the full staged diff; commit the exact paths, merge to `main`, rerun merged-main tests, push, verify remote equality, reinstall the merged Release app, and remove the feature worktree and branch.

## Recovery and stop condition

If a provider contract changes, only its reader remains unavailable; other values and last-good readings continue. Rollback is a normal revert of the feature commit because the feature introduces no persisted schema or credential mutation.

Stop only when the installed AgentGrid bundle displays four verified provider values, Hermes remains fully usable as a terminal CLI, merged `main` equals `origin/main`, the worktree is clean and removed, and the Phase run validates complete.
