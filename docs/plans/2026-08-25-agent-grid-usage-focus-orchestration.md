# AgentGrid Usage, Focus, and Permission Orchestration Implementation Plan

> **For the executor:** REQUIRED SUB-SKILL: Use `executing-plans`, `test-driven-development`, `systematic-debugging`, `swiftui-expert-skill`, and `verification-before-completion` while executing this plan task by task.

**Goal:** Ship AgentGrid 1.3.4 with dynamic multi-window provider usage, automatic foreground recovery polling, authenticated Grok ACP billing, compact four-provider rows, app-level focus retention, and a stable signed permission identity.

**Architecture:** Provider adapters emit semantic window observations into an actor that owns per-window last-good state. A separate actor schedules eligible provider reads from lifecycle/network/manual events. A main-actor observable model projects snapshots into a four-column SwiftUI rail. A main-actor focus state machine distinguishes explicit user switch gestures from programmatic activation. Release builds use a fixed Apple Development team identity and fixed install path; supported permission preflight reports real missing access without altering TCC.

**Tech stack:** Swift 6 strict concurrency, Observation, SwiftUI, AppKit, ApplicationServices, Network (`NWPathMonitor`), Foundation subprocess/JSON-RPC, SQLite3, Swift Testing, XcodeGen, macOS 15+.

---

## Execution contract

- Execute only in `.worktrees/codex/usage-focus-orchestration` on branch `codex/usage-focus-orchestration` until merged-main delivery.
- Preserve unrelated work, all five CLI launch/maintenance paths, grid/tab/PTTY lifecycle, duplicate selections, Work-root policy, and Hermes behavior.
- Do not read, fixture, print, persist, or commit real tokens, cookies, credential payloads, raw authenticated provider responses, key events, TCC data, or quota history.
- Keep `ENABLE_APP_SANDBOX=NO` and `ENABLE_HARDENED_RUNTIME=YES`.
- Do not add protected-resource usage descriptions or entitlements unless production code actually uses that resource. Accessibility is needed only for the optional global key-event mask; local AgentGrid events and globally monitored mouse events remain available without claiming that trust. This plan does not need camera, microphone, location, screen capture, contacts, calendar, Bluetooth, or direct Apple Events access.
- Never edit a TCC database or claim to programmatically grant Full Disk Access/Accessibility. One explicit user consent migration may be needed when replacing the current ad-hoc bundle with the first stably signed bundle.
- Use `apply_patch` for source/doc edits and `xcodegen generate` for the generated project. Review generated drift before accepting it.
- Every regular test command must keep `/tmp/AgentGridLiveUsageTests.enabled` absent. Stop and investigate if it exists; do not silently run live-account tests.
- Commit/push/merge/install only after all gates in Task 9 pass. No App Store submission is part of this repair.

Use this command prefix for every test run:

```bash
test ! -e /tmp/AgentGridLiveUsageTests.enabled
xcodebuild \
  -project AgentGrid.xcodeproj \
  -scheme AgentGrid \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation \
  <test filters> test
```

Baseline at plan creation: commit `3ee7720`; 90 tests passed and the one live-provider test skipped.

## Task 1: Replace the scalar domain with semantic provider snapshots

**Behavior seam:** Multiple windows from one provider retain semantic identity, percentages, resets, and independent freshness.

**Create:**

- `Sources/AgentGrid/ProviderUsageSnapshot.swift`

**Modify:**

- `Sources/AgentGrid/CLIUsageState.swift`
- `Sources/AgentGrid/CLIUsageReading.swift`
- `Tests/AgentGridTests/CLIUsageTests.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)

1. Add failing tests for:
   - four-provider snapshot order;
   - stable semantic window IDs independent of array order;
   - successful replacement of only one window;
   - provider failure marking every last-good window for that provider stale without changing other providers;
   - malformed known window marking only that window stale;
   - explicit null/inactive removal;
   - first failure producing provider-level unavailable;
   - 0...100 clamping and retained reset dates.
2. Add the source-file declarations, run `xcodegen generate`, and prove the red state:

   ```bash
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/CLIUsageTests test
   ```

   Expected red reason: `ProviderUsageSnapshot`, semantic observations, and per-window merge APIs do not exist.
3. Implement the value types, `ProviderQuotaReading.fetchObservation()`, and actor-owned last-good merge. Remove the scalar `fetchRemainingPercent()` contract only after every provider has a compiling migration stub.
4. Keep error strings sanitized and provider-specific. Do not persist the cache.
5. Rerun the focused command until green, then run `ProviderUsageReaderTests` to catch migration compile failures.

## Task 2: Preserve Codex, Claude, and Cursor windows and resets

**Behavior seam:** Each adapter emits every meaningful active window its current authoritative surface provides.

**Modify:**

- `Sources/AgentGrid/CodexUsageReader.swift`
- `Sources/AgentGrid/CodexUsageResponseParser.swift`
- `Sources/AgentGrid/ClaudeUsageReader.swift`
- `Sources/AgentGrid/CursorUsageReader.swift`
- `Sources/AgentGrid/ProviderUsageHTTPTransport.swift`
- `Tests/AgentGridTests/ProviderUsageReaderTests.swift`
- `Tests/AgentGridTests/LiveProviderUsageTests.swift`

1. Add synthetic failing cases for:
   - Codex primary + secondary with `windowDurationMins` and Unix `resetsAt`;
   - Codex explicit-null secondary removal and malformed-primary/valid-secondary partial success;
   - Claude five-hour + seven-day + named model windows with independent resets;
   - Claude inactive/null removal and one malformed model window beside valid account windows;
   - expired Claude login skipping quota transport, usage 401 mapping to a sanitized `/login` action without retry, and last-good Claude windows becoming stale without credential mutation;
   - Cursor two monthly pools with cycle end;
   - Cursor legacy composite fallback and missing-field-not-zero behavior.
2. Prove red:

   ```bash
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/ProviderUsageReaderTests test
   ```

   Expected red reason: current parsers return one `Int` and discard resets/parallel windows.
3. Implement provider-local DTOs and observation translation. IDs use source keys; display strings never determine identity.
4. Parse reset timestamps to `Date` and keep formatting out of readers.
5. Update the gated live test to require at least one fresh window per provider and validate every returned percent/reset shape without printing raw payloads. Keep its marker disabled during normal runs.
6. Run `ProviderUsageReaderTests` and `CLIUsageTests` together until green.

## Task 3: Replace Grok auth-file REST with authenticated ACP billing

**Behavior seam:** A scripted fake ACP process proves the live canonical wire sequence `initialize` then `_x.ai/billing` with `params: {}`, without a real token, network request, or invented `authenticate` exchange.

**Create:**

- `Sources/AgentGrid/GrokACPUsageClient.swift`
- `Tests/Fixtures/FakeGrokACP/main.swift`

**Modify:**

- `Sources/AgentGrid/GrokUsageReader.swift`
- `Sources/AgentGrid/CLIUsageReading.swift`
- `Tests/AgentGridTests/ProviderUsageReaderTests.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)

1. Add a fixture executable target that accepts newline-delimited JSON-RPC and returns deterministic initialize/billing responses. It must contain no provider credentials and no network code.
2. Add failing tests for:
   - exact executable arguments `--no-auto-update agent stdio`;
   - protocol version 1 initialize before billing;
   - exact wire method `_x.ai/billing`, which ACP routes as semantic extension `x.ai/billing`;
   - required empty object `params: {}` (not an omitted params member);
   - no `authenticate` request when the canonical locally authenticated process serves billing directly;
   - included weekly/monthly percentage and `currentPeriod.end` reset;
   - optional on-demand percentage only when enabled and cap is positive;
   - deprecated monthly-field fallback;
   - method-not-found, auth failure, malformed line, early EOF, timeout, cancellation, bounded stderr, and child termination;
   - no use of `~/.grok/auth.json` and no direct billing URL request.
3. Regenerate, then prove red:

   ```bash
   xcodegen generate
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/ProviderUsageReaderTests test
   ```

   Expected red reason: production still injects an auth-file loader/HTTP transport and has no ACP process client.
4. Implement one bounded ACP subprocess owner. After initialize, send `_x.ai/billing` with `params: {}` directly. Treat auth/method errors as sanitized unavailable states; do not add an ACP `authenticate` request unless a future canonical CLI version first proves that requirement at the credential-safe probe and fixture seams. Close stdin/stdout/stderr on exit, terminate on cancellation/timeout, and cap stderr before converting it to a sanitized diagnostic.
5. Remove `GrokAccessTokenStore`, `GrokAuthTokenParser`, the Grok REST request, and their obsolete tests. Keep the shared HTTP transport for Claude/Cursor only.
6. Run the focused tests. Run a secret-oriented diff search:

   ```bash
   git diff --check
   git diff -- . ':!docs/**' | rg -n 'auth\.json|cli-chat-proxy|Bearer |accessToken|refreshToken'
   ```

   Expected result: no Grok auth-file/proxy implementation and no literal credentials; intentional Claude/Cursor field names must be reviewed individually.

## Task 4: Add deterministic 60-second foreground orchestration

**Behavior seam:** A fake clock and fake lifecycle stream advance the coordinator without wall-clock sleeps or live network.

**Create:**

- `Sources/AgentGrid/CLIUsageRefreshCoordinator.swift`
- `Sources/AgentGrid/UsageLifecycleMonitor.swift`
- `Tests/AgentGridTests/CLIUsageRefreshCoordinatorTests.swift`

**Modify:**

- `Sources/AgentGrid/CLIUsageReading.swift`
- `Sources/AgentGrid/CLIUsageModel.swift`
- `Sources/AgentGrid/AgentGridApp.swift`
- `Sources/AgentGrid/AgentGridWorkspaceView.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)

1. Add failing fake-clock tests for:
   - one immediate launch pass;
   - no second pass before 60 seconds;
   - one pass at each 60-second foreground boundary;
   - timer suspension while inactive;
   - immediate activation, wake/screen-wake, and unsatisfied-to-satisfied network recovery;
   - no refresh for satisfied-to-satisfied noise;
   - in-flight trigger union and exactly one follow-up pass;
   - independent provider backoff at 60/120/240/480/900 seconds;
   - success resetting only that provider's backoff;
   - one manual/lifecycle override during backoff;
   - cancellation removing timers/observers and cancelling the active read.
2. Regenerate and prove red:

   ```bash
   xcodegen generate
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/CLIUsageRefreshCoordinatorTests test
   ```

   Expected red reason: scheduler and lifecycle event types do not exist.
3. Implement the coordinator actor with injected `Clock`/jitter and a provider-set pending queue. Do not put sleeps in `CLIUsageModel`.
4. Implement `UsageLifecycleMonitor` as a narrow adapter over app active state, workspace wake/screen wake notifications, and `NWPathMonitor` recovery. Balance every observer/start with removal/cancel.
5. Own the model/coordinator once at app scope. Remove the workspace view's one-shot `.task { await usage.start() }`; pass presentation state down and route the refresh button to an explicit manual trigger.
6. Run the new suite plus `CLIUsageTests`, `RuntimePolicyTests`, and `TerminalLaunchGateTests`.

## Task 5: Render the compact four-provider multi-row rail

**Behavior seam:** Pure formatting/layout helpers turn snapshots into deterministic provider columns and accessible row descriptions.

**Create:**

- `Sources/AgentGrid/ProviderUsageRow.swift`
- `Tests/AgentGridTests/ProviderUsagePresentationTests.swift`

**Modify:**

- `Sources/AgentGrid/CLIUsageBar.swift`
- `Sources/AgentGrid/CLIUsageSegment.swift`
- `Sources/AgentGrid/CLIUsageModel.swift`
- `Sources/AgentGrid/AgentGridWorkspaceView.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)

1. Add failing tests for deterministic provider/window ordering, reset formatting at same-day/cross-day boundaries, stale `Last updated` text, unavailable/loading text, and complete accessibility labels.
2. Regenerate and prove red:

   ```bash
   xcodegen generate
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/ProviderUsagePresentationTests test
   ```

   Expected red reason: the current segment accepts one scalar state and fixes the rail at 42 points.
3. Build four equal provider columns with stable nested `ForEach` IDs. Extract the window row instead of nesting business logic in `body`.
4. Keep the rail at 32 points with one compact line normally and at most two for multi-window providers. Show labels and percentages visually; retain reset, last-updated, and failure detail in tooltip/accessibility text, with an explicit stale/unavailable warning marker.
5. Keep the orange visual language, monospaced percentages, Reduce Motion behavior for the refresh control, real refresh `Button`, help text, and accessibility grouping.
6. Run the presentation, CLI usage, tab model, and terminal launch suites. Build Debug to catch SwiftUI generic/type-check failures.

## Task 6: Implement focus intent gating and the helper app

**Behavior seam:** A fake activation client distinguishes a one-use user lease from a programmatic activation; a fixture app supplies the real manual seam.

**Create:**

- `Sources/AgentGrid/ApplicationFocusRetentionController.swift`
- `Sources/AgentGrid/FocusIntentMonitor.swift`
- `Tests/AgentGridTests/ApplicationFocusRetentionTests.swift`
- `Tests/FocusStealFixture/FocusStealFixtureApp.swift`

**Modify:**

- `Sources/AgentGrid/AgentGridApp.swift`
- `Sources/AgentGrid/WindowMaximizer.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)

1. Add failing unit tests for:
   - controller arms only while AgentGrid is active with a visible normal window;
   - local AgentGrid events, globally observed outside mouse events, and the explicit one-shot command create one 1.5-second lease;
   - Command-Tab is classified by whichever monitor actually receives it, without assuming a global monitor receives AgentGrid-dispatched events;
   - the global key mask is enabled only with Accessibility trust, while local key and global mouse monitoring remain available without it;
   - an activation within the lease is allowed and disarms until AgentGrid returns;
   - expired/no lease requests AgentGrid activation and re-keys its existing window;
   - the decision waits 120 milliseconds for asynchronous global input delivery;
   - repeat steals coalesce into one recovery sequence that retries every 250 milliseconds for at most five seconds;
   - explicit user switch never triggers delayed reacquisition;
   - disable/enable focus-retention command and observer cleanup.
2. Add the helper application target with bundle ID `com.thechosenvictor.AgentGridFocusStealFixture`. In `--programmatic` mode it self-activates after launch; normal mode has one explicit activation button and an obvious fixture-only label.
3. Regenerate and prove red:

   ```bash
   xcodegen generate
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/ApplicationFocusRetentionTests test
   ```

   Expected red reason: no application focus state machine, event adapter, or helper target exists.
4. Implement the `@MainActor` controller and narrow AppKit adapter. Install both `NSEvent.addLocalMonitorForEvents` and `NSEvent.addGlobalMonitorForEvents`: the local handler observes AgentGrid-dispatched events and returns them unchanged; the global handler observes outside mouse events and adds key events only when Accessibility is trusted. Use `NSWorkspace.didActivateApplicationNotification` and the existing main window. The postflight browser-automation repair uses `activateIgnoringOtherApps` only after the explicit-intent decision window closes because cooperative activation cannot recover from a non-yielding app.
5. Add `Commands` menu items for `Allow Next App Switch` and focus retention on/off with accessible titles/shortcuts. Do not add a settings sidebar or disturb terminal shortcuts.
6. Run focus, runtime policy, terminal focus, and tab suites. Build the helper and main app.
7. Reserve the real programmatic/click/Command-Tab/typing matrix for Task 9 manual validation; do not treat unit tests as visual proof.

## Task 7: Add quiet permission readiness and stable signing identity

**Behavior seam:** Preflight is read-only/quiet on launch, explicit prompting is user-initiated, and two distinct Release builds satisfy the same designated requirement.

**Create:**

- `Sources/AgentGrid/PermissionReadiness.swift`
- `Sources/AgentGrid/PermissionReadinessView.swift`
- `Tests/AgentGridTests/PermissionReadinessTests.swift`
- `scripts/verify-local-release-signing.sh`
- `scripts/install-local-release.sh`

**Modify:**

- `Sources/AgentGrid/AgentGridApp.swift`
- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)
- `README.md`

1. Add failing tests for:
   - launch/activation preflight calls `AXIsProcessTrustedWithOptions` with prompt false;
   - repeated preflight never changes to prompt true;
   - only the explicit permission action requests Accessibility/open settings;
   - trusted status removes the warning on the next activation without relaunch;
   - actual required file-operation `EPERM`/`EACCES` becomes a specific readiness issue;
   - unrelated missing files do not claim Full Disk Access is absent;
   - no API reads/writes a TCC database;
   - when Accessibility is unavailable, global key observation is disabled while local AgentGrid events, global mouse events, and the one-shot switch remain active and the limitation is reported precisely.
2. Prove the application test red:

   ```bash
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/PermissionReadinessTests test
   ```

   Expected red reason: readiness abstractions and UI do not exist.
3. Implement quiet supported preflight and one non-modal readiness surface. Preserve terminal sessions if permission state changes. Do not create a fake generic Full Disk Access probe; report failure from the actual protected operation.
4. In `project.yml`, keep the fixed bundle ID and set Manual Release signing to certificate team `<team ID>` with exact identity `Apple Development: <maintainer email> (<label>)` and no ad-hoc fallback. Certificate inspection, not the label suffix, is authoritative: `OU=<team ID>`; `<label>` is not the TeamIdentifier. Preserve hardened runtime and unsandboxed behavior. Add no unused entitlement or Info.plist usage description.
5. Add a failing shell verifier first. It must reject ad-hoc/no-team bundles and validate:
   - `codesign --verify --deep --strict`;
   - authority contains `Apple Development`;
   - `TeamIdentifier=<team ID>`, with a regression proving the identity label suffix `<label>` is not accepted as TeamIdentifier;
   - bundle ID `com.thechosenvictor.AgentGrid`;
   - hardened-runtime flag present;
   - compiled entitlements do not enable App Sandbox or unused protected capabilities;
   - installed path is exactly `~/Applications/AgentGrid.app` when install validation is requested.
6. Add the installer using an explicit source bundle and fixed destination. It must verify before replacement, copy without post-sign mutation, verify after replacement, and leave a recoverable previous bundle until postflight succeeds. It must not use a broad glob or delete outside the exact app sibling paths.
7. Regenerate, then build two distinct Release products:

   ```bash
   security find-identity -v -p codesigning
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid -configuration Release \
     -derivedDataPath DerivedData-sign-a -skipPackagePluginValidation \
     DEVELOPMENT_TEAM=<team ID> CODE_SIGN_STYLE=Manual \
     CODE_SIGN_IDENTITY='Apple Development: <maintainer email> (<label>)' \
     CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid -configuration Release \
     -derivedDataPath DerivedData-sign-b -skipPackagePluginValidation \
     DEVELOPMENT_TEAM=<team ID> CODE_SIGN_STYLE=Manual \
     CODE_SIGN_IDENTITY='Apple Development: <maintainer email> (<label>)' \
     CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CURRENT_PROJECT_VERSION=9 build
   ```
8. Run the verifier on both. Capture each `codesign -d -r-` output and require exact designated-requirement equality. Run `spctl --assess --type execute --verbose=4` and record its result, but do not fail or claim Developer ID/notarization based on an Apple Development local build.
9. Run permission tests, full signature script tests, and `git diff --check`.

## Task 8: Integrate lifecycle, failure, and regression coverage

**Modify:**

- `Tests/AgentGridTests/CLIUsageTests.swift`
- `Tests/AgentGridTests/CLIUsageRefreshCoordinatorTests.swift`
- `Tests/AgentGridTests/ProviderUsageReaderTests.swift`
- `Tests/AgentGridTests/ApplicationFocusRetentionTests.swift`
- `Tests/AgentGridTests/PermissionReadinessTests.swift`
- `Tests/AgentGridTests/RuntimePolicyTests.swift`
- `Tests/AgentGridTests/TerminalLaunchGateTests.swift`

1. Add cross-boundary tests for:
   - network recovery during provider backoff followed by fresh/stale mixed windows;
   - app activation caused by focus recovery coalescing with the usage activation refresh;
   - refresh completion while the app becomes inactive;
   - wake plus network recovery producing one follow-up pass;
   - permission warning not taking terminal first responder;
   - user app switch leaving the usage timer inactive until AgentGrid returns;
   - closing the app cancels ACP, HTTP, timer, path monitor, and event monitors.
2. Prove each test red for its intended missing integration, then implement the smallest composition change in the owner module. Do not weaken assertions to match implementation timing.
3. Run all focused suites together:

   ```bash
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -derivedDataPath DerivedData -skipPackagePluginValidation \
     -only-testing:AgentGridTests/CLIUsageTests \
     -only-testing:AgentGridTests/CLIUsageRefreshCoordinatorTests \
     -only-testing:AgentGridTests/ProviderUsageReaderTests \
     -only-testing:AgentGridTests/ProviderUsagePresentationTests \
     -only-testing:AgentGridTests/ApplicationFocusRetentionTests \
     -only-testing:AgentGridTests/PermissionReadinessTests \
     -only-testing:AgentGridTests/RuntimePolicyTests \
     -only-testing:AgentGridTests/TerminalLaunchGateTests test
   ```

4. Review concurrency isolation and task ownership. There must be one scheduler, one lifecycle monitor, one focus monitor, and no detached unowned task.

## Task 9: Version, docs, installed-app validation, and delivery

**Modify:**

- `project.yml`
- `AgentGrid.xcodeproj/project.pbxproj` (generated)
- `README.md`
- `CONTEXT-MAP.md`
- `THIRD_PARTY_NOTICES.md` only if copied/reference code requires a new notice
- the authoritative portfolio tracker required by the active Work workflow

1. Set `MARKETING_VERSION: 1.3.4` and `CURRENT_PROJECT_VERSION: 9`, monotonically superseding the installed build 8 after the compact-footer and live-provider corrections. Update README/context truth for:
   - every provider window/reset and per-window stale behavior;
   - 60-second foreground plus lifecycle/network refresh;
   - Grok ACP credential ownership;
   - focus retention and explicit-switch commands;
   - one-time permission migration and fixed installed path;
   - stable Apple Development local signing limits.
2. Run `xcodegen generate`, save the generated project diff, run it again, and require no second-generation diff.
3. Run formatting/static checks:

   ```bash
   git diff --check
   rg -n 'TODO|FIXME|placeholder|activateIgnoringOtherApps|TCC\.db|cli-chat-proxy\.grok\.com' \
     Sources Tests scripts README.md CONTEXT-MAP.md project.yml
   git status --short
   ```

   Review each match; expected production matches for deprecated focus APIs, TCC DB access, and direct Grok proxy are zero.
4. Run the complete suite without live network:

   ```bash
   test ! -e /tmp/AgentGridLiveUsageTests.enabled
   xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid \
     -configuration Debug -derivedDataPath DerivedData \
     -skipPackagePluginValidation test
   ```

   Require all non-live tests pass and exactly the gated live provider test skip.
5. Build Debug and signed Release from a clean DerivedData path. Run icon verification, signature verification, generated-project drift, secret scan, and exact changed-file review.
6. Install the verified signed Release at `~/Applications/AgentGrid.app` with `scripts/install-local-release.sh`. Register only that path with LaunchServices. Do not launch any other build path.
7. Complete the one-time permission migration if macOS no longer associates the ad-hoc build's prior grants. Grant only Accessibility and Full Disk Access to the fixed installed AgentGrid bundle through supported System Settings. Relaunch twice and verify there is no repeated prompt and the readiness warning clears.
8. Manually inspect at 800-point minimum width and a large maximized window:
   - four equal provider columns and every returned window;
   - visible percentage, stale/unavailable marker, loading, and refresh states, plus reset/failure tooltip and accessibility detail;
   - no clipping with the provider that has the most rows;
   - light/dark appearance, Reduce Motion, keyboard navigation, tooltips, and VoiceOver labels/order.
9. Run the focus helper matrix from the installed app:
   - helper `--programmatic` is rejected and AgentGrid regains key/frontmost state;
   - clicking the helper and Command-Tab switching are allowed and remain allowed;
   - returning to AgentGrid re-arms retention;
   - typing continuously in the top-left terminal while triggering a programmatic steal leaves subsequent text in AgentGrid;
   - disabling retention and `Allow Next App Switch` behave exactly as labeled;
   - no focus loop, hidden window, duplicate window, or lost terminal first responder occurs.
10. Validate unrestricted terminal behavior from a pane using real read/write/process/network operations in the Work root and an actually protected path covered by the granted permission. Verify all five canonical CLIs still launch in YOLO mode and current-version maintenance invokes no updater.
11. Validate polling with timestamps while the installed app is foreground, inactive, reactivated, slept/woken, and taken offline/online. Require 60-second foreground cadence, zero inactive periodic reads, immediate recovery, provider-local backoff, and coalescing.
12. Review every changed file and the complete staged diff. Reconcile against this plan, the design, project instructions, and owner tracker.
13. Commit the exact reviewed paths, push the feature branch, merge to `main`, rerun focused + full tests and signed Release verification on merged `main`, push `main`, verify `main == origin/main`, reinstall the merged Release, and repeat signature/designated-requirement/install-path postflight.
14. After authoritative installed-app and remote equality proof, remove only the task worktree/branch and task-created DerivedData/helper residue. Preserve the recoverable prior app until the new installed app passes both-launch postflight, then remove that exact backup and report whether recovery remains available.

## Recovery and stop conditions

- A provider contract failure leaves only that provider/window stale or unavailable. Revert its adapter without changing the snapshot/UI contract.
- If Grok ACP reports method-not-found, confirm the maintained canonical CLI version. Do not restore direct auth-file billing.
- If modern activation requests are denied by macOS, preserve the manual-switch escape, capture the exact helper trace, and fix the state machine; do not reintroduce deprecated force-activation APIs.
- If the exact Apple Development identity cannot produce team `<team ID>` and an identical designated requirement across two builds, do not replace the installed app. Keep the last verified bundle and diagnose identity selection; never substitute the label suffix `<label>` for the certificate team.
- If Accessibility or Full Disk Access requires consent, present the supported one-time migration. Do not modify TCC or misreport consent as complete.
- Stop only when 1.3.4 build 9 is signed with the stable identity, installed at the fixed path, all non-live tests/build/signature gates pass, every meaningful provider window refreshes correctly, explicit user switches remain allowed, programmatic steals are rejected in the manual fixture, permission readiness remains quiet on two launches, documentation/tracker truth is current, and merged `main` equals its remote.
