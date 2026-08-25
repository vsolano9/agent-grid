# AgentGrid CLI maintenance implementation plan

> Historical note: This plan delivered AgentGrid 1.3.0 build 4. Its unconditional updater behavior was superseded by the conditional-update and quota-rail amendment in AgentGrid 1.3.1 build 5; the current behavior is documented in the maintenance design and ADR-002.

> **For the executor:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Update every supported CLI on each AgentGrid launch, repair and verify stable CLI aliases, and prevent terminal setup from using a broken or stale executable.

**Architecture:** A deep `CLIMaintenanceService` coordinates catalog policy and injected process/filesystem adapters. A main-actor observable model drives a contextual startup gate and constructs the existing terminal configuration only after alias verification.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/Observation, Foundation `Process`, Swift Testing, XcodeGen, macOS 15.

---

## Execution constraints

- Writer: current Codex task in `.worktrees/launch-cli-maintenance` on `feature/launch-cli-maintenance`.
- Preserve terminal arguments, retained PTYs, working-directory policy, six-grid limit, credentials, shell startup files, and unrelated files.
- Use direct executable URLs and argument arrays. Never construct updater commands from user-controlled shell text.
- Attempt every updater even after failure. Only verified alias failure blocks launch.
- Bump to marketing version 1.3.0/build 4 after behavior is green, then regenerate the tracked project.
- Rollback is `bf10b28`; the previously installed 1.2.0 bundle remains recoverable until 1.3.0 postflight passes.
- Stop only after tests, builds, runtime and visual proof, docs, review, installed-app postflight, commit/push/merge, remote equality, and worktree cleanup are complete.

## Slice 1: Maintenance catalog and report policy

**Public seam:** `CLIMaintenanceService.perform()` returns one ordered result per supported `AgentKind`, attempts every update, and distinguishes a verified fallback warning from a broken alias.

**Create:** `Sources/AgentGrid/CLIMaintenance.swift`, `Tests/AgentGridTests/CLIMaintenanceTests.swift`

1. Add focused tests for exact official updater commands, deterministic CLI order, continuing after updater failure, warning when verification passes, and blocking when verification fails.
2. Run `xcodebuild ... -only-testing:AgentGridTests/CLIMaintenanceTests test`; expect compile failures because the maintenance API does not exist.
3. Implement value types, protocols, catalog policy, and the minimum orchestration needed for green tests.
4. Rerun the focused suite, then all tests.

## Slice 2: Process and canonical-alias adapters

**Public seam:** the real runner returns bounded output/exit/timeout state, while the alias store atomically maps each canonical command to a working non-self target.

**Create:** `Sources/AgentGrid/CLICommandRunner.swift`, `Sources/AgentGrid/CanonicalCLIAliasStore.swift`, `Tests/AgentGridTests/CLICommandRunnerTests.swift`, `Tests/AgentGridTests/CanonicalCLIAliasStoreTests.swift`

1. Add temp-directory tests for successful version capture, nonzero exit, pre-cancelled no-spawn behavior, synchronized descendant termination, missing executable, provider-aware discovery, candidate preflight and discovery rejection with verified fallback, fallback warning propagation, link creation, atomic replacement, wrong-target replacement, stable-link indirection, direct and indirect self-target refusal, Hermes environment sanitation, and directory refusal.
2. Run both focused suites; expect compile failures at the missing adapter APIs.
3. Implement the runner as an actor and the alias store with same-directory temporary links plus atomic rename.
4. Rerun focused suites and the complete suite. Review all concurrency diagnostics before continuing.

## Slice 3: Startup gate and post-maintenance configuration

**Public seam:** `CLIMaintenanceModel` runs once, exposes accurate five-step progress, retries from a fresh state, and produces `AgentGridConfiguration` only after a launchable report.

**Create:** `Sources/AgentGrid/CLIMaintenanceModel.swift`, `Sources/AgentGrid/CLIMaintenanceView.swift`, `Tests/AgentGridTests/CLIMaintenanceModelTests.swift`

**Modify:** `Sources/AgentGrid/AgentGridApp.swift`, `Sources/AgentGrid/GridSetupView.swift`

1. Add main-actor tests for initial, running, warning-ready, failed, and retry transitions.
2. Run the focused suite; expect compile failures at the missing model.
3. Implement the observable model and contextual maintenance surface. Delay `AgentGridConfiguration.live()` until report launchability is proven; surface verified update warnings non-modally in grid setup.
4. Rerun focused and complete tests, then Debug build.

## Slice 4: Version, documentation, runtime proof, and delivery

**Modify:** `project.yml`, generated `AgentGrid.xcodeproj/project.pbxproj`, `README.md`, `CONTEXT-MAP.md`

1. Update user and owner documentation for every-launch maintenance, canonical aliases, warning/failure behavior, and recovery.
2. Set version 1.3.0/build 4, run `xcodegen generate`, and prove a second regeneration is zero-diff.
3. Run focused maintenance suites, the complete suite, Debug and Release builds, icon verification, forbidden-artifact/secret scans, and complete diff review.
4. Exercise the service against disposable CLI fixtures for success, failure-with-working-fallback, broken-alias blocking, and retry. Inspect the startup surface manually at normal and narrow sizes with VoiceOver labels and Reduce Motion.
5. Repair/update the real five CLIs through the built app, verify `~/.local/bin/{codex,claude,grok,cursor-agent,hermes}` with direct `--version` calls and resolved targets, launch a four-pane grid, and verify process arguments, working directory, and teardown.
6. Commit and push the feature branch, merge into updated `main`, rerun authoritative tests, install the Release app, launch/postflight once more, push `main`, remove the worktree/branch, and verify local/remote SHA equality.
