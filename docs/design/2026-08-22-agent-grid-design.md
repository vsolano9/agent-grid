# AgentGrid design

## Outcome

AgentGrid is a native macOS utility with one normal maximized window containing four equal embedded terminal panes. On launch, the panes start Codex, Claude, Grok, and Cursor Agent in their respective auto-approval modes inside `/Volumes/Extreme Pro/Documents/Work`.

## Constraints

- Normal maximized window, never native fullscreen.
- Fixed 2x2 terminal grid with no sidebar, tabs, toolbar, settings, or pane headers.
- Real PTYs via SwiftTerm v1.20.0; no simulated terminal output.
- No app-owned network layer, telemetry, credential storage, or command history.
- No automatic process restart. A process exit remains visible in its pane until the app is reopened.

## Commands

| Pane | Executable | Auto-approval arguments |
| --- | --- | --- |
| Codex | `codex` | `--dangerously-bypass-approvals-and-sandbox` |
| Claude | `claude` | `--dangerously-skip-permissions` |
| Grok | `grok` | `--always-approve` |
| Cursor | `cursor-agent` | `--yolo` |

## Visual direction

The app uses the terminal's native near-black surface and the CLI's own colors. One-pixel separators establish the four regions. The normal macOS title bar remains the only app chrome.

Reference jobs:

- Tide Guide iPad App Store image: dense native information hierarchy only.
- Chronicle motion still: restrained near-black layering and native-feeling transition framing only.
- SwiftTerm v1.20.0 sample and API: real PTY behavior and AppKit embedding convention.

The generated concept at `agent-grid-concept.png` is an internal direction artifact. Keep its strict 2x2 hierarchy, hairline separators, title bar, and focus legibility. Replace all fake status content with the real CLIs. Reject its presentation-board shadow, fake metrics, custom branding, and decorative animation.

## Interaction and states

The signature transition is the standard window appearing and immediately occupying the active screen's visible frame, followed by real PTY initialization and terminal output. Reduce Motion uses the same final frame without custom animation.

Owned states are limited to initial process launch, live PTY, keyboard focus, missing executable, and exited process. Missing or broken commands display truthful terminal errors. If the fixed Work directory is unavailable, the app falls back to the user's home directory.

## Validation

- Unit tests prove launch order, executable names, exact arguments, working directory selection, binary resolution, environment construction, and window frame policy.
- Runtime postflight proves a maximized non-fullscreen window, four visible terminal panes, four real child CLI processes, keyboard input, and clean process teardown.
- Release budget: app bundle under 50 MB excluding external CLIs; app-shell idle CPU under 2% after initialization.

## Sources

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), MIT license, tag v1.20.0.
- [Cursor CLI parameters](https://docs.cursor.com/en/cli/reference/parameters).
- [Anthropic Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage).
- Local private references are recorded in the shared image-reference library `SOURCES.tsv` and are not redistributed.
