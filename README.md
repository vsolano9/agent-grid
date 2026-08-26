# AgentGrid

Current local release: **1.3.5 (10)**.

AgentGrid is a lightweight native macOS app that opens four real terminal sessions in each grid of one maximized window. On launch—and whenever a new grid is created—you choose the CLI for each position:

| CLI | Auto-approval mode |
| --- | --- |
| Codex | `--dangerously-bypass-approvals-and-sandbox` |
| Claude | `--dangerously-skip-permissions` |
| Grok | `--always-approve` |
| Cursor Agent | `--yolo` |
| Hermes Agent | `--yolo` |

Every position is independent, so combinations such as four Codex sessions or four Hermes Agent sessions are supported. AgentGrid remembers the four CLI choices separately for each numbered grid and restores them on later launches. Each grid also has an independent working directory, defaulting to the Work root below. A grid starts its terminals only after `Launch Grid` is selected. The compact tab strip can keep up to six independent grids open. `⌘T` opens a fresh grid setup, and `⌘1` through `⌘6` switch between open grids. Switching preserves every running terminal session and every unlaunched selection; a tab's close button terminates only that grid's PTYs. AgentGrid still has no sidebars, pane headers, or settings.

Before terminal setup appears, AgentGrid checks Codex, Claude, Grok, Cursor Agent, and Hermes Agent in order. It installs a CLI only when its official version check reports a newer release, then repairs the stable launchers under `~/.local/bin` and verifies every launcher with `--version`. A failed check or update is shown as a warning when the previously installed provider launcher still verifies. A missing or broken command blocks terminal launch and offers Retry, so a grid never starts with an unusable CLI alias.

A 32-point four-column status strip along the bottom shows the label and remaining percentage for every meaningful account quota window returned by Codex, Claude, Grok, and Cursor, using at most two compact lines. This includes Codex primary and secondary windows, Claude account and named-model windows, Grok included and enabled on-demand quotas, and Cursor's separate Cursor Models and Other Models pools or its applicable legacy monthly pool. Reset, last-updated, and failure detail remain available in each row's tooltip and accessibility label instead of consuming workspace height. Stale and unavailable providers also show an explicit warning marker; loading and unavailable text remain explicit. Hermes is intentionally absent because it routes work through underlying providers rather than owning a comparable account quota.

Usage refreshes immediately at launch, every 60 seconds while AgentGrid is active, and immediately after activation, workspace or screen wake, and network recovery. Periodic reads suspend while inactive. Concurrent triggers coalesce, and provider-local failures back off independently without suppressing healthy providers. The refresh button requests a fresh reading within the same coalescing and backoff policy.

Focus Retention is enabled by default. It rejects short-lived programmatic attempts to steal the active AgentGrid window while leaving explicit clicks and Command-Tab app switches alone. Use **Focus → Allow Next App Switch** (`⌃⌥⌘A`) for the next intentional switch or **Focus → Disable Focus Retention** (`⌃⌥⌘F`) to turn retention off. AgentGrid uses modern cooperative AppKit activation and never the deprecated force-activation API.

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

Local Release builds use the exact Apple Development identity `Apple Development: victor.solanonunez@gmail.com (RC5PWHKSF3)` with certificate team identifier `9UKJNG8B38`, hardened runtime, the fixed bundle ID, and no App Sandbox. (`RC5PWHKSF3` is part of the certificate label, not its TeamIdentifier.) Verify a Release before installation, then use the recoverable fixed-path installer:

```bash
scripts/verify-local-release-signing.sh /path/to/AgentGrid.app
scripts/verify-local-release-pair.sh /path/to/build-a/AgentGrid.app /path/to/build-b/AgentGrid.app
scripts/install-local-release.sh /path/to/AgentGrid.app
scripts/verify-local-release-signing.sh --installed /Users/victor/Applications/AgentGrid.app
```

The installer preserves the previous bundle at `/Users/victor/Applications/AgentGrid.app.previous` until postflight is complete. AgentGrid checks Accessibility quietly at launch and app activation; it never prompts or opens System Settings without an explicit click. Accessibility only extends focus-intent detection to global keyboard events; local keyboard intent, outside mouse intent, and **Allow Next App Switch** remain available without it. The first move from the older ad-hoc build to this stable identity may require one user-approved permission migration. AgentGrid cannot grant itself Full Disk Access and reports protected-file readiness only after an actual required provider credential/config read returns `EPERM` or `EACCES`; a successful retry clears that issue. Apple Development signing is stable for this Mac and preserves the app's designated identity across local updates, but it is not notarized distribution signing and cannot bypass macOS consent.

The generated Xcode project pins [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) to version 1.20.0. Provider usage integration was informed by the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar); attribution is retained in `THIRD_PARTY_NOTICES.md`. CI is intentionally local-only.

## Safety

Every selected agent starts in its unrestricted/auto-approval mode. They can execute commands and modify files without asking for confirmation. AgentGrid stores only the four selected CLI names for each numbered grid in macOS preferences. It stores no credentials, quota history, prompts, terminal state, working-directory choice, or telemetry. Startup maintenance invokes official version checks, an official updater only when needed, and `--version`; it does not change authentication or provider configuration. The usage rail reads Claude's native `/usage` output first and falls back to the existing Claude OAuth credential, while Cursor uses its read-only state database, Codex uses its authenticated app-server session, and Grok uses the installed CLI's canonical ACP billing method (`initialize`, then `_x.ai/billing`). AgentGrid never refreshes or rewrites Claude-owned OAuth credentials: if both native usage and OAuth fallback fail because the login expired, it shows a sanitized instruction to run `/login` in Claude Code while any last-good Claude quota remains stale. AgentGrid does not read Grok credentials directly, and secrets and provider payloads are never logged or persisted.

## License

MIT
