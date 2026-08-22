# AgentGrid context map

## Product

AgentGrid is a native macOS developer utility. Its single normal window maximizes to the active screen's visible frame and embeds four equal SwiftTerm PTYs for Codex, Claude, Grok, and Cursor Agent.

## Source of truth

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition, deployment target, and pinned dependency |
| `Sources/AgentGrid/AgentLaunchSpec.swift` | Pane order, executable names, and exact YOLO arguments |
| `Sources/AgentGrid/RuntimePolicy.swift` | Working-directory and environment policy |
| `Sources/AgentGrid/TerminalPane.swift` | SwiftTerm/AppKit bridge and PTY lifecycle |
| `Sources/AgentGrid/WindowMaximizer.swift` | Normal maximized-window behavior |
| `Tests/AgentGridTests/` | Launch, resolution, environment, window, and lifecycle contracts |
| `docs/design/2026-08-22-agent-grid-design.md` | Approved product and visual design |

## Durable decisions

- The window is maximized, never native fullscreen.
- The UI is a fixed 2×2 grid with no additional navigation or controls.
- PTYs launch only after their views are attached and have a non-zero layout.
- The default working directory is `/Volumes/Extreme Pro/Documents/Work`, with home-directory fallback.
- The app does not restart exited agents or persist terminal state.
- SwiftTerm is pinned to 1.20.0.

## Validation

Regenerate `AgentGrid.xcodeproj` after changing `project.yml` or adding source files. Use the `AgentGrid` scheme for macOS tests and builds. Runtime validation must confirm the exact four process arguments, visible terminal output, a non-fullscreen visible-frame window, input focus, and teardown.
