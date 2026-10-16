# AgentGrid Multi-Grid Tabs Implementation Plan

> **For the executor:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Ship a polished Notepad++-inspired tab strip supporting up to six independent, retained four-agent terminal grids.

**Architecture:** A pure observable `GridTabsModel` owns naming, limits, selection, and close policy. A retained `TerminalGridDeck` keeps every terminal subtree mounted and changes only presentation, while the existing AppKit bridge owns one-shot focus activation and close teardown.

**Tech Stack:** Swift 6, SwiftUI Observation, AppKit, SwiftTerm 1.20.0, Swift Testing, XcodeGen, XcodeBuildMCP, macOS Accessibility.

---

## Constraints and ownership

- Writer: `codex/multi-grid-tabs` in `.worktrees/multi-grid-tabs` owns all AgentGrid repository changes.
- Preserve CLI order, exact YOLO arguments, workspace, bundle identity, normal maximized behavior, and existing terminal teardown semantics.
- Keep one to six grids. Do not persist or restore terminal sessions across launches.
- Build and test with XcodeBuildMCP; regenerate the project after adding source or test files.
- Install only after a signed Release build passes tests and review.

## Slice 1: Prove tab policy

**Create:** `Tests/AgentGridTests/GridTabsModelTests.swift`

**Create:** `Sources/AgentGrid/GridTabsModel.swift`

1. Add tests for initial state, add/select, monotonic naming, active/inactive close selection, final-tab protection, stable surviving IDs, and the six-grid limit.
2. Regenerate `AgentGrid.xcodeproj` and run the focused test suite. Expected red: `GridTabsModel` is unresolved.
3. Implement the smallest `@MainActor @Observable` model with `addGrid`, `select`, and `close` behaviors.
4. Run focused and full Debug tests. Expected green: all tab-policy and baseline tests pass.

## Slice 2: Retain sessions and transfer focus

**Modify:** `Sources/AgentGrid/TerminalLaunchGate.swift`

**Modify:** `Tests/AgentGridTests/TerminalLaunchGateTests.swift`

**Modify:** `Sources/AgentGrid/TerminalPane.swift`

**Modify:** `Sources/AgentGrid/TerminalGridView.swift`

1. Add failing activation-gate tests proving focus is claimed only by the preferred pane on inactive-to-active transitions.
2. Implement the pure gate, then wire active state through the grid to `TerminalPane`.
3. Add `TerminalGridDeck` with a stable `ForEach` inside a `ZStack`; selected state changes opacity, hit testing, z-order, and accessibility only.
4. Run focused and full Debug tests. Review view identity to ensure switching does not remove a terminal subtree.

## Slice 3: Ship the tab strip

**Create:** `Sources/AgentGrid/AgentGridWorkspaceView.swift`

**Create:** `Sources/AgentGrid/GridTabStrip.swift`

**Modify:** `Sources/AgentGrid/AgentGridApp.swift`

1. Build the 39-point horizontally scrolling strip from native buttons using the approved active, inactive, hover, close, add, disabled, and keyboard states.
2. Use a 140 ms ease-out transition for tab changes and disable it under Reduce Motion.
3. Wire `⌘T` and `⌘1`–`⌘6`; add accessibility labels, hints, selected traits, grouping, close controls, and tooltips.
4. Run the full Debug suite and build Debug. Inspect warnings and resolve every in-scope issue.

## Slice 4: Owner-surface verification and delivery

**Modify:** `README.md`, `CONTEXT-MAP.md`

1. Build Release, verify the compiled icon/catalog and strict code signature, replace `~/Applications/AgentGrid.app`, refresh LaunchServices, and relaunch.
2. Add two grids and switch repeatedly. Confirm 12 exact child CLI processes for three grids, hidden-session process IDs remain stable, selected terminal accepts input, closing one grid removes exactly four child processes, and the window remains maximized but not fullscreen.
3. Inspect the installed tab strip at full window size and a narrower window; verify hover, close, scrolling, keyboard shortcuts, and reduced-motion equivalent where observable.
4. Review every changed file and the complete diff; scan for secrets, placeholders, unrelated work, private references, and task residue.
5. Commit the logical feature, fast-forward merge to `main`, push `origin/main`, verify the remote commit, remove the worktree/branch, and close phase evidence.

## Rollback and stop condition

Rollback is commit `46a7913`. Stop only when model and lifecycle tests pass, Release builds cleanly, the installed app proves independent retained process sets through add/switch/close, focus and shortcuts work, the visual result matches the approved design contract, `origin/main` matches local `main`, and task residue is cleaned.
