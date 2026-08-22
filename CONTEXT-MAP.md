# AgentGrid context map

## Product

AgentGrid is a native macOS developer utility. Its single normal window maximizes to the active screen's visible frame and hosts up to six independent tabs, each containing four equal SwiftTerm PTYs for Codex, Claude, Grok, and Cursor Agent.

## Source of truth

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition, deployment target, and pinned dependency |
| `Sources/AgentGrid/AgentLaunchSpec.swift` | Pane order, executable names, and exact YOLO arguments |
| `Sources/AgentGrid/RuntimePolicy.swift` | Working-directory and environment policy |
| `Sources/AgentGrid/GridTabsModel.swift` | One-to-six tab, naming, selection, and close policy |
| `Sources/AgentGrid/GridTabStrip.swift` | Custom tab states, shortcuts, motion, and accessibility |
| `Sources/AgentGrid/AgentGridWorkspaceView.swift` | Tab strip and retained terminal-deck composition |
| `Sources/AgentGrid/TerminalPane.swift` | SwiftTerm/AppKit bridge and PTY lifecycle |
| `Sources/AgentGrid/WindowMaximizer.swift` | Normal maximized-window behavior |
| `Tests/AgentGridTests/` | Launch, resolution, environment, window, and lifecycle contracts |
| `docs/design/2026-08-22-agent-grid-design.md` | Approved product and visual design |
| `docs/design/2026-08-22-agent-grid-tabs-design.md` | Approved multi-grid interaction and visual contract |
| `docs/decisions/001-retain-terminal-grids-in-view-tree.md` | Session-retention architecture decision |
| `docs/design/agent-grid-icon-master.png` | Approved 1024 px icon source |
| `scripts/generate-app-icon.swift` | Deterministic macOS icon-size generation |
| `scripts/verify-app-icon.sh` | Compiled bundle icon regression check |

## Durable decisions

- The window is maximized, never native fullscreen.
- Each tab is a fixed 2×2 grid; the only navigation is the compact top tab strip.
- One to six grids may be open. Switching keeps every PTY mounted; closing a tab terminates and reaps exactly its four children.
- PTYs launch only after their views are attached and have a non-zero layout.
- The default working directory is `/Volumes/Extreme Pro/Documents/Work`, with home-directory fallback.
- The app does not restart exited agents or persist terminal state.
- SwiftTerm is pinned to 1.20.0.
- All catalog icon sizes are generated from the approved master; never redraw them independently.

## Validation

Regenerate `AgentGrid.xcodeproj` after changing `project.yml` or adding source files. Use the `AgentGrid` scheme for macOS tests and builds. Runtime validation must confirm exact process arguments per grid, stable PIDs through tab switches, selected-grid input focus, four-child teardown without zombies, visible terminal output, and a non-fullscreen visible-frame window.
