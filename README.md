# AgentGrid

AgentGrid is a lightweight native macOS app that opens four real terminal sessions in each grid of one maximized window. On launch—and whenever a new grid is created—you choose the CLI for each position:

| CLI | Auto-approval mode |
| --- | --- |
| Codex | `--dangerously-bypass-approvals-and-sandbox` |
| Claude | `--dangerously-skip-permissions` |
| Grok | `--always-approve` |
| Cursor Agent | `--yolo` |
| Hermes Agent | `--yolo` |

Every position is independent, so combinations such as four Codex sessions are supported. Each grid also has an independent working directory, defaulting to the Work root below. A grid starts its terminals only after `Launch Grid` is selected. The compact tab strip can keep up to six independent grids open. `⌘T` opens a fresh grid setup, and `⌘1` through `⌘6` switch between open grids. Switching preserves every running terminal session and every unlaunched selection; a tab's close button terminates only that grid's PTYs. AgentGrid still has no sidebars, pane headers, or settings.

Before terminal setup appears, AgentGrid checks Codex, Claude, Grok, Cursor Agent, and Hermes Agent in order. It installs a CLI only when its official version check reports a newer release, then repairs the stable launchers under `~/.local/bin` and verifies every launcher with `--version`. A failed check or update is shown as a warning when the previously installed provider launcher still verifies. A missing or broken command blocks terminal launch and offers Retry, so a grid never starts with an unusable CLI alias.

A compact rail along the bottom shows live account quota remaining for Codex, Claude, Grok, and Cursor, such as `Codex 55% left`. AgentGrid reads the same authenticated local state used by each installed client, requests each provider's account-level usage endpoint in parallel, and keeps the last successful value visibly stale if a later refresh fails. Claude reports the most constrained active window so the single percentage never hides a tighter weekly or model-specific limit. Hermes is intentionally absent because it routes work through those underlying providers rather than owning a comparable account quota. The refresh button requests a fresh reading.

## Requirements

- macOS 15 or newer
- Xcode 26 or newer to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Codex, Claude, Grok, Cursor Agent, and Hermes Agent installed
- Network access on launch when CLI updates are available

The app places `~/.local/bin` first in every terminal's `PATH`. It resolves updater targets from the inherited `PATH` plus common Homebrew and user CLI folders, then maintains these canonical commands:

```text
~/.local/bin/codex
~/.local/bin/claude
~/.local/bin/grok
~/.local/bin/cursor-agent
~/.local/bin/hermes
```

AgentGrid does not edit shell startup files. If maintenance cannot resolve or verify a command, install that CLI through its official installer and select Retry.

Authentication and model/provider setup remain owned by each CLI. A newly installed Hermes pane opens its normal provider setup prompt until `hermes setup` has been completed.

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

The generated Xcode project pins [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) to version 1.20.0. Provider usage integration was informed by the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar); attribution is retained in `THIRD_PARTY_NOTICES.md`. CI is intentionally local-only.

## Safety

Every selected agent starts in its unrestricted/auto-approval mode. They can execute commands and modify files without asking for confirmation. AgentGrid itself stores no credentials, quota history, prompts, terminal state, selections, or telemetry. Startup maintenance invokes official version checks, an official updater only when needed, and `--version`; it does not change authentication or provider configuration. The usage rail reads credentials from the existing Claude Keychain item, Grok auth file, Cursor read-only state database, and Codex app-server session only long enough to request current quota; secrets and provider payloads are never logged or persisted.

## License

MIT
