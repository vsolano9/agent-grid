# AgentGrid

AgentGrid is a lightweight native macOS app that opens four real terminal sessions in each grid of one maximized window. On launch—and whenever a new grid is created—you choose the CLI for each position:

| CLI | Auto-approval mode |
| --- | --- |
| Codex | `--dangerously-bypass-approvals-and-sandbox` |
| Claude | `--dangerously-skip-permissions` |
| Grok | `--always-approve` |
| Cursor Agent | `--yolo` |

Every position is independent, so combinations such as four Codex sessions are supported. Each grid also has an independent working directory, defaulting to the Work root below. A grid starts its terminals only after `Launch Grid` is selected. The compact tab strip can keep up to six independent grids open. `⌘T` opens a fresh grid setup, and `⌘1` through `⌘6` switch between open grids. Switching preserves every running terminal session and every unlaunched selection; a tab's close button terminates only that grid's PTYs. AgentGrid still has no sidebars, pane headers, settings, or app-owned services.

## Requirements

- macOS 15 or newer
- Xcode 26 or newer to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Each CLI you intend to select installed and authenticated: `codex`, `claude`, `grok`, or `cursor-agent`

The app searches the inherited `PATH` plus common Homebrew and user CLI folders. A missing command produces a normal `env` error inside only that pane.

## Working directory

Every new grid defaults to:

```text
/Volumes/Extreme Pro/Documents/Work
```

Use `Change…` during grid setup to choose another folder for that grid. The choice freezes when the grid launches; the next new grid starts at the Work default again. If the Work folder is unavailable, AgentGrid falls back to the current user's home directory. macOS asks for removable-volume access the first time this external-volume folder is used; choose **Allow** to keep the Work directory as the default terminal root.

## Build and test

```bash
xcodegen generate
xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid -configuration Debug test
```

Regenerate the complete macOS icon set from the approved 1024 px master with:

```bash
swift scripts/generate-app-icon.swift \
  docs/design/agent-grid-icon-master.png \
  Resources/Assets.xcassets/AppIcon.appiconset
```

After a Release build, verify that Xcode compiled the icon and asset catalog:

```bash
scripts/verify-app-icon.sh /path/to/AgentGrid.app
```

The generated Xcode project pins [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) to version 1.20.0. CI is intentionally local-only.

## Safety

Every selected agent starts in its unrestricted/auto-approval mode. They can execute commands and modify files without asking for confirmation. AgentGrid itself stores no credentials, history, prompts, terminal state, selections, or telemetry.

## License

MIT
