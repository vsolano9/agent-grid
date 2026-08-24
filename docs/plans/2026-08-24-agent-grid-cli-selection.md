# AgentGrid Per-Grid CLI Selection Implementation Plan

> **For the executor:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Require a duplicate-safe four-slot CLI choice and an independent working-directory choice for Grid 1 at launch and for every new grid, with Work remaining the default and retained-PTY behavior preserved.

**Architecture:** A fixed four-slot selection and working-directory value live in each tab. Tabs begin as drafts and transition once to launched. The live executable catalog expands the frozen ordered selection into four launch specs carrying that grid's frozen directory, while the retained terminal deck mounts only launched grids.

**Tech Stack:** Swift 6, SwiftUI/Observation, SwiftTerm 1.20.0, Swift Testing, XcodeGen, macOS 15.

---

## Execution constraints

- Writer: current Codex session, isolated branch `feature/custom-cli-grid` and worktree `.worktrees/custom-cli-grid`.
- Preserve `/Volumes/Extreme Pro/Documents/Work`, the six-grid cap, retained terminal identity, exact YOLO arguments, and non-fullscreen window behavior.
- Follow red-green-refactor for every behavior slice. Do not change the generated `.xcodeproj` by hand.
- Bump the app to marketing version 1.2.0/build 3 only after behavior is green, then regenerate the tracked project.
- Stop condition: full tests/builds, manual runtime and visual checks, docs, cleanup, reviewed diff, committed/pushed branch, merged/pushed `main`, installed app postflight, and no unreported requirement gap.

## Slice 1: Duplicate-safe launch selection

**Public seam:** `AgentGridSelection` and `AgentLaunchCatalog` return exactly four ordered specs for any valid selection, including repeated kinds.

**Modify:** `Sources/AgentGrid/AgentLaunchSpec.swift`, `Sources/AgentGrid/TerminalGridView.swift`

**Test:** `Tests/AgentGridTests/AgentLaunchCatalogTests.swift`

1. Add tests for a four-Codex selection, exact repeated arguments/workspace, and invalid selection cardinality.
2. Run `xcodebuild ... -only-testing:AgentGridTests/AgentLaunchCatalogTests test`; expect the new tests to fail because selection-aware APIs do not exist.
3. Implement the fixed selection value and catalog expansion without weakening per-kind resolution or missing-command fallback.
4. Rerun the focused suite, then the full suite; expect zero failures.

## Slice 2: Per-grid draft and launch lifecycle

**Public seam:** `GridTabsModel` starts every tab as a draft, preserves slot edits, launches once, and refuses to mutate a running grid.

**Modify:** `Sources/AgentGrid/GridTabsModel.swift`

**Test:** `Tests/AgentGridTests/GridTabsModelTests.swift`

1. Add tests for initial draft state, duplicate slot changes, one-way launch, new-grid draft defaults, independent drafts, and post-launch immutability.
2. Run the focused model suite; expect failures at the missing draft/launch API.
3. Implement the minimum model changes while preserving tab identity, naming, selection, close, and cap behavior.
4. Rerun focused and full tests; expect zero failures.

## Slice 3: Position-based focus

**Public seam:** `TerminalGridView` assigns focus preference to slot zero only, independent of selected CLI kind.

**Modify:** `Sources/AgentGrid/TerminalGridView.swift`

**Test:** `Tests/AgentGridTests/TerminalLaunchGateTests.swift` or a new pure layout-policy test in the same target.

1. Add a failing test proving four Codex panes yield exactly one preferred-focus slot.
2. Implement a small position policy and use indexed specs in the 2×2 view.
3. Rerun the focused and full suites.

## Slice 4: Setup UI and retained deck integration

**Public seam:** first launch and every added grid visibly present four selectors and mount no terminals until `Launch Grid N`; launched grids remain retained through tab changes.

**Create:** `Sources/AgentGrid/GridSetupView.swift`

**Modify:** `Sources/AgentGrid/AgentGridWorkspaceView.swift`, `Sources/AgentGrid/TerminalGridView.swift`, `Sources/AgentGrid/GridTabStrip.swift`

1. Wire the selected draft tab to a native four-row `Picker` setup view with descriptive labels, accessibility, Work-path copy, and a launch button.
2. Keep launched grids in the retained `ZStack`; draft tabs render no terminal view.
3. Add restrained 140 ms transition behavior with a Reduce Motion equivalent and no continuous animation.
4. Run focused model/catalog suites and the full suite, then build Debug.

## Slice 5: Product state, visual evidence, and delivery

**Modify:** `README.md`, `CONTEXT-MAP.md`, `project.yml`, generated `AgentGrid.xcodeproj/project.pbxproj`

**Add:** `docs/design/agent-grid-cli-selection-concept.png`

1. Copy the inspected generated direction board into the established design folder and record its SHA-256.
2. Update owner docs for selectable duplicate CLIs, launch/new-grid setup, focus, and unchanged Work directory.
3. Bump version/build, run `xcodegen generate`, and prove project source/file references are current with a regenerate-and-diff check.
4. Run the full test suite, Debug build, Release build, app icon verification, repository audits, and complete diff review.
5. Launch the built app; manually inspect first-launch setup, selector states, four Codex launch, `⌘T` setup, tab switching, close behavior, and Reduce Motion. Verify child arguments/PIDs, Work cwd, no pre-launch children, no fullscreen flag, teardown/reaping, idle CPU, and bundle size.
6. Install the verified Release app to the existing local AgentGrid application location if present, then repeat version and launch postflight against the installed bundle.
7. Commit, push the feature branch, merge into updated `main`, rerun authoritative tests on `main`, push `main`, remove the feature worktree/branch, and verify local/remote commit equality.
