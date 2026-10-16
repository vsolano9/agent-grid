# AgentGrid

Latest release: **1.4.0 (11)**. See [CHANGELOG.md](CHANGELOG.md).

AgentGrid is a lightweight native macOS app that opens four real terminal sessions in each grid of one maximized window. On launch—and whenever a new grid is created—you choose the CLI for each position:

| CLI | Auto-approval mode |
| --- | --- |
| Codex | `--dangerously-bypass-approvals-and-sandbox` |
| Claude | `--dangerously-skip-permissions` |
| Grok | `--always-approve` |
| Cursor Agent | `--yolo` |
| Hermes Agent | `--yolo` |

Every position is independent, so combinations such as four Codex sessions or four Hermes Agent sessions are supported. AgentGrid remembers the four CLI choices separately for each numbered grid and restores them on later launches. Each grid also has an independent working directory, defaulting to the last folder you chose (your home folder until you choose one). A grid starts its terminals only after `Launch Grid` is selected. The compact tab strip can keep up to six independent grids open. `⌘T` opens a fresh grid setup, and `⌘1` through `⌘6` switch between open grids. Switching preserves every running terminal session and every unlaunched selection; a tab's close button terminates only that grid's PTYs. AgentGrid still has no sidebars, pane headers, or settings.

Before terminal setup appears, AgentGrid checks Codex, Claude, Grok, Cursor Agent, and Hermes Agent in order. It installs a CLI only when its official version check reports a newer release, then repairs the stable launchers under `~/.local/bin` and verifies every launcher with `--version`. Hermes is the deliberate exception: AgentGrid reports an available Hermes update but never runs its updater, because a managed or customized Hermes checkout must remain under its owner's control. A failed check or update is shown as a warning when the previously installed provider launcher still verifies. A missing or broken command blocks terminal launch and offers Retry, so a grid never starts with an unusable CLI alias.

A 32-point four-column status strip along the bottom shows the label and remaining percentage for every meaningful account quota window returned by Codex, Claude, Grok, and Cursor, using at most two compact lines. This includes Codex primary and secondary windows, Claude account and named-model windows, Grok included and enabled on-demand quotas, and Cursor's separate Cursor Models and Other Models pools or its applicable legacy monthly pool. Reset, last-updated, and failure detail remain available in each row's tooltip and accessibility label instead of consuming workspace height. Stale and unavailable providers also show an explicit warning marker; loading and unavailable text remain explicit. Hermes is intentionally absent because it routes work through underlying providers rather than owning a comparable account quota.

Usage refreshes immediately at launch, every 60 seconds while AgentGrid is active, and immediately after activation, workspace or screen wake, and network recovery. Periodic reads suspend while inactive. Concurrent triggers coalesce, and provider-local failures back off independently without suppressing healthy providers. The refresh button requests a fresh reading within the same coalescing and backoff policy.

Focus Retention is enabled by default. It rejects short-lived programmatic attempts to steal the active AgentGrid window while leaving explicit clicks and Command-Tab app switches alone. Use **Focus → Allow Next App Switch** (`⌃⌥⌘A`) for the next intentional switch or **Focus → Disable Focus Retention** (`⌃⌥⌘F`) to turn retention off. After its bounded intent-classification delay, AgentGrid force-activates only to recover from a switch that was not user-authorized; the explicit-switch lease always wins.

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

AgentGrid does not edit shell startup files. If maintenance cannot resolve or verify a command, install that CLI through its official installer and select Retry. Update customized Hermes installations from their owning repository rather than through AgentGrid.

Authentication and model/provider setup remain owned by each CLI. A newly installed Hermes pane opens its normal provider setup prompt until `hermes setup` has been completed.

## Working directory

The first grid starts in your home folder. Use `Change…` during grid setup to choose another folder for that grid. AgentGrid remembers the last folder you chose as the default for every new grid, including after a relaunch. A grid's folder freezes when the grid launches, so a later choice never moves a running grid. If the remembered folder is missing when AgentGrid starts (for example, an external drive that is not mounted), new grids start in your home folder until you choose again. macOS may ask once for access when the folder is on a removable volume or in a protected location such as Documents; choose **Allow** so the terminals can use it.

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

## Install

Build a Release app and copy it to `~/Applications`:

```bash
xcodegen generate
xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build
mkdir -p ~/Applications
ditto build/Build/Products/Release/AgentGrid.app ~/Applications/AgentGrid.app
open ~/Applications/AgentGrid.app
```

`CODE_SIGN_IDENTITY=-` signs the app ad hoc for this Mac only. macOS ties Accessibility permission to the signature, so an ad-hoc build asks again after every rebuild. To keep the permission across updates, sign with your own certificate instead: replace the two signing lines with `CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<your team ID> CODE_SIGN_IDENTITY="Apple Development"`. AgentGrid is not notarized for distribution.

AgentGrid checks Accessibility quietly at launch and app activation; it never prompts or opens System Settings without an explicit click. Accessibility only extends focus-intent detection to global keyboard events; local keyboard intent, outside mouse intent, and **Allow Next App Switch** remain available without it. AgentGrid cannot grant itself Full Disk Access and reports protected-file readiness only after an actual required provider credential/config read returns `EPERM` or `EACCES`; a successful retry clears that issue.

The `scripts/` folder also holds the maintainer's release checks (`verify-local-release-signing.sh`, `verify-local-release-pair.sh`, `install-local-release.sh`). They are pinned to the maintainer's own certificate and install path, so other builds use the steps above.

The generated Xcode project uses the repository-owned SwiftTerm 1.20.0 snapshot in `Vendor/SwiftTerm`, pinned to upstream commit `5d14406844143538cd8f8851d2d8a67c1fe443e5` with AgentGrid's bounded Kitty-transfer patch documented alongside it. Provider usage integration was informed by the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar); attribution is retained in `THIRD_PARTY_NOTICES.md`. CI is intentionally local-only.

## Safety

Every selected agent starts in its unrestricted/auto-approval mode. They can execute commands and modify files without asking for confirmation. AgentGrid stores only the four selected CLI names for each numbered grid and the default working-directory path in macOS preferences. It stores no credentials, quota history, prompts, terminal state, or telemetry. Startup maintenance invokes official version checks, supported provider updaters only when needed, and `--version`; it never runs the Hermes updater and does not change authentication or provider configuration. The usage rail reads Claude's native `/usage` output first and falls back to the existing Claude OAuth credential, while Cursor uses its read-only state database, Codex uses its authenticated app-server session, and Grok uses the installed CLI's canonical ACP billing method (`initialize`, then `_x.ai/billing`). AgentGrid never refreshes or rewrites Claude-owned OAuth credentials: if both native usage and OAuth fallback fail because the login expired, it shows a sanitized instruction to run `/login` in Claude Code while any last-good Claude quota remains stale. AgentGrid does not read Grok credentials directly, and secrets and provider payloads are never logged or persisted.

## License

MIT
