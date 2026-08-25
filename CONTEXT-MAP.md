# AgentGrid context map

## Product

AgentGrid is a native macOS developer utility. Its single normal window maximizes to the active screen's visible frame and hosts up to six independent tabs. Each tab begins with four duplicate-safe CLI selectors plus an independent working-directory choice and, once launched, contains four equal SwiftTerm PTYs in the selected order and directory.

## Source of truth

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition, deployment target, and pinned dependency |
| `Sources/AgentGrid/AgentLaunchSpec.swift` | Four-slot selection, executable names, and exact YOLO arguments |
| `Sources/AgentGrid/RuntimePolicy.swift` | Working-directory and environment policy |
| `Sources/AgentGrid/CLIMaintenance.swift` | Ordered every-launch updater, verification policy, and report model |
| `Sources/AgentGrid/CLICommandRunner.swift` | Bounded, cancellable updater and version subprocess execution |
| `Sources/AgentGrid/CanonicalCLIAliasStore.swift` | Atomic `~/.local/bin` alias repair and target safety |
| `Sources/AgentGrid/CLIMaintenanceModel.swift` | Main-actor launch gate and retry state |
| `Sources/AgentGrid/CLIMaintenanceView.swift` | Startup progress and blocking failure surface |
| `Sources/AgentGrid/GridTabsModel.swift` | One-to-six draft/launch tab, naming, selection, and close policy |
| `Sources/AgentGrid/GridTabStrip.swift` | Custom tab states, shortcuts, motion, and accessibility |
| `Sources/AgentGrid/GridSetupView.swift` | Four-position CLI, per-grid working-directory, and launch surface |
| `Sources/AgentGrid/AgentGridWorkspaceView.swift` | Tab strip and retained terminal-deck composition |
| `Sources/AgentGrid/TerminalPane.swift` | SwiftTerm/AppKit bridge and PTY lifecycle |
| `Sources/AgentGrid/WindowMaximizer.swift` | Normal maximized-window behavior |
| `Tests/AgentGridTests/` | Launch, resolution, environment, window, and lifecycle contracts |
| `docs/design/2026-08-22-agent-grid-design.md` | Approved product and visual design |
| `docs/design/2026-08-22-agent-grid-tabs-design.md` | Approved multi-grid interaction and visual contract |
| `docs/design/2026-08-24-agent-grid-cli-selection-design.md` | Per-grid CLI selection and launch contract |
| `docs/decisions/001-retain-terminal-grids-in-view-tree.md` | Session-retention architecture decision |
| `docs/decisions/002-gate-terminal-launch-on-cli-maintenance.md` | Every-launch update and verified-alias gate decision |
| `docs/design/agent-grid-icon-master.png` | Approved 1024 px icon source |
| `scripts/generate-app-icon.swift` | Deterministic macOS icon-size generation |
| `scripts/verify-app-icon.sh` | Compiled bundle icon regression check |

## Durable decisions

- The window is maximized, never native fullscreen.
- Each tab is a fixed 2×2 grid; the only navigation is the compact top tab strip.
- Every app launch and new grid starts with four independent CLI selectors. Repeated kinds, including four Codex panes, are valid.
- Every new grid defaults to `/Volumes/Extreme Pro/Documents/Work`; a different folder may be chosen independently before launch.
- Launch freezes that grid's CLI and working-directory selections. Running grids are not reconfigured in place.
- One to six grids may be open. Switching keeps every running PTY mounted and every draft selection intact; closing a running tab terminates and reaps exactly its four children.
- PTYs launch only after their views are attached and have a non-zero layout.
- The top-left position is the sole initial-focus pane, independent of CLI kind.
- The per-grid default working directory is `/Volumes/Extreme Pro/Documents/Work`, with home-directory fallback when unavailable.
- Every app launch attempts official updates for Codex, Claude, Grok, Cursor Agent, and Hermes Agent before terminal configuration exists.
- `~/.local/bin` is first in terminal `PATH`; its five canonical CLI names are atomically repaired and verified with `--version` on launch.
- An updater failure is non-blocking only when the repaired alias verifies. An alias failure blocks all terminal launch until Retry succeeds.
- AgentGrid does not edit shell profiles, credentials, or provider configuration during maintenance.
- The app does not restart exited agents or persist terminal state.
- SwiftTerm is pinned to 1.20.0.
- All catalog icon sizes are generated from the approved master; never redraw them independently.

## Validation

Regenerate `AgentGrid.xcodeproj` after changing `project.yml` or adding source files. Use the `AgentGrid` scheme for macOS tests and builds. Runtime validation must confirm all five updater attempts, direct success of every canonical alias, no terminal child before maintenance and grid launch, duplicate selection support, exact process arguments per grid, the permanent Work cwd, stable PIDs through tab switches, selected-grid input focus, four-child teardown without zombies, visible terminal output, and a non-fullscreen visible-frame window.
