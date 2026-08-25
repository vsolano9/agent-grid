# AgentGrid context map

## Product

AgentGrid is a native macOS developer utility. Its single normal window maximizes to the active screen's visible frame and hosts up to six independent tabs. Each tab begins with four duplicate-safe CLI selectors plus an independent working-directory choice and, once launched, contains four equal SwiftTerm PTYs in the selected order and directory.

The current installed local release is AgentGrid 1.3.4 build 9 at `/Users/victor/Applications/AgentGrid.app`. After successful postflight, the rotated build 9 backup was moved recoverably to `/Users/victor/.Trash/AgentGrid.app.previous-20260825-2314`; no `.previous` remains at the install path. Feature commit `31d2b0c` was fast-forwarded to `main` and pushed, and local `main` equals `origin/main`. Merged `main` passed 205/205 tests and the installer passed 36/36 tests. A clean merged-`main` Release was built, signed, and reinstalled; the installed executable is byte-identical to the merged artifact at SHA-256 `9e6aa93f625a3d836226e0eb9641fa997792d134b4638212485bb1de40942971`.

Installed-app validation confirms fresh quota from Codex, Claude, Grok, and Cursor, a visually correct 32-point strip, successful manual refresh, retained macOS Accessibility and Full Disk Access authorization value 2, rejection of a programmatic focus steal, and working focus-retention disable/enable plus one-shot explicit-switch controls. A clean second launch and the post-install launch both opened without a readiness or permission banner and showed all four providers fresh with the 32-point rail intact.

Still open: installed-app manual matrix cases not yet directly exercised, including click and Command-Tab switching, typing continuity through a focus steal, appearance/Reduce Motion/keyboard/VoiceOver coverage, real terminal and CLI operations, and foreground/inactive/wake/network cadence.

## Source of truth

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition, deployment target, and pinned dependency |
| `Sources/AgentGrid/AgentLaunchSpec.swift` | Four-slot selection, executable names, and exact YOLO arguments |
| `Sources/AgentGrid/RuntimePolicy.swift` | Working-directory and environment policy |
| `Sources/AgentGrid/CLIMaintenance.swift` | Ordered every-launch version checks, conditional updater, alias verification policy, and report model |
| `Sources/AgentGrid/CLICommandRunner.swift` | Bounded, cancellable updater and version subprocess execution |
| `Sources/AgentGrid/CLIExecutableLocator.swift` | Provider-aware executable discovery outside canonical aliases |
| `Sources/AgentGrid/CanonicalCLIAliasStore.swift` | Atomic `~/.local/bin` alias repair and target safety |
| `Sources/AgentGrid/CLIMaintenanceModel.swift` | Main-actor launch gate and retry state |
| `Sources/AgentGrid/CLIMaintenanceView.swift` | Startup progress and blocking failure surface |
| `Sources/AgentGrid/CLIUsageReading.swift` | Honest per-provider quota capability and live reader composition |
| `Sources/AgentGrid/CodexUsageReader.swift` | Local Codex app-server quota handshake |
| `Sources/AgentGrid/ClaudeUsageReader.swift` | Claude Keychain credential loading and OAuth usage reader |
| `Sources/AgentGrid/GrokUsageReader.swift` | Grok billing quota translation |
| `Sources/AgentGrid/GrokACPUsageClient.swift` | Canonical authenticated Grok ACP billing exchange and bounded process ownership |
| `Sources/AgentGrid/CursorUsageReader.swift` | Read-only Cursor SQLite auth loading and usage-summary reader |
| `Sources/AgentGrid/ProviderUsageHTTPTransport.swift` | Isolated, testable provider HTTP transport |
| `Sources/AgentGrid/ProviderUsageSnapshot.swift` | Semantic multi-window provider state and per-window stale merge |
| `Sources/AgentGrid/CLIUsageBar.swift` | Compact bottom quota rail and manual refresh control |
| `Sources/AgentGrid/ProviderUsageRow.swift` | Multi-row provider presentation, reset localization, and accessibility text |
| `Sources/AgentGrid/CLIUsageRefreshCoordinator.swift` | Foreground cadence, lifecycle recovery, coalescing, and provider-local backoff |
| `Sources/AgentGrid/UsageLifecycleMonitor.swift` | App activation, wake, screen-wake, and network event adapter |
| `Sources/AgentGrid/ApplicationFocusRetentionController.swift` | User-intent focus lease and bounded cooperative re-keying policy |
| `Sources/AgentGrid/FocusIntentMonitor.swift` | Balanced AppKit local/global event and app-activation monitoring |
| `Sources/AgentGrid/PermissionReadiness.swift` | Quiet Accessibility preflight and actual protected-read denial reporting |
| `Sources/AgentGrid/GridTabsModel.swift` | One-to-six draft/launch tab, naming, selection, and close policy |
| `Sources/AgentGrid/GridSelectionStore.swift` | Versioned per-grid CLI-choice persistence in macOS preferences |
| `Sources/AgentGrid/GridTabStrip.swift` | Custom tab states, shortcuts, motion, and accessibility |
| `Sources/AgentGrid/GridSetupView.swift` | Four-position CLI, per-grid working-directory, and launch surface |
| `Sources/AgentGrid/AgentGridWorkspaceView.swift` | Tab strip and retained terminal-deck composition |
| `Sources/AgentGrid/TerminalPane.swift` | SwiftTerm/AppKit bridge and PTY lifecycle |
| `Sources/AgentGrid/WindowMaximizer.swift` | Normal maximized-window behavior |
| `Tests/AgentGridTests/` | Launch, resolution, environment, window, and lifecycle contracts |
| `docs/design/2026-08-22-agent-grid-design.md` | Approved product and visual design |
| `docs/design/2026-08-22-agent-grid-tabs-design.md` | Approved multi-grid interaction and visual contract |
| `docs/design/2026-08-24-agent-grid-cli-selection-design.md` | Per-grid CLI selection and launch contract |
| `docs/design/2026-08-25-agent-grid-usage-focus-orchestration-design.md` | Current multi-window usage, refresh, focus-retention, and durable-permission architecture |
| `docs/decisions/001-retain-terminal-grids-in-view-tree.md` | Session-retention architecture decision |
| `docs/decisions/002-gate-terminal-launch-on-cli-maintenance.md` | Every-launch check, conditional update, and verified-alias gate decision |
| `docs/plans/2026-08-25-agent-grid-conditional-updates-and-usage.md` | AgentGrid 1.3.1 acceptance and delivery plan |
| `docs/plans/2026-08-25-agent-grid-usage-focus-orchestration.md` | AgentGrid 1.3.4 implementation, validation, signing, and installed-app acceptance plan |
| `docs/design/agent-grid-icon-master.png` | Approved 1024 px icon source |
| `scripts/generate-app-icon.swift` | Deterministic macOS icon-size generation |
| `scripts/verify-app-icon.sh` | Compiled bundle icon regression check |

## Durable decisions

- The window is maximized, never native fullscreen.
- Each tab is a fixed 2×2 grid; the only navigation is the compact top tab strip.
- Every app launch and new grid starts with four independent CLI selectors. Repeated kinds, including four Codex panes, are valid.
- Each numbered grid's four CLI choices are saved immediately to a versioned UserDefaults record and restored when that grid number is created on a later app launch. Invalid records fall back to the standard layout.
- Every new grid defaults to `/Volumes/Extreme Pro/Documents/Work`; a different folder may be chosen independently before launch.
- Launch freezes that grid's CLI and working-directory selections. Running grids are not reconfigured in place.
- One to six grids may be open. Switching keeps every running PTY mounted and every draft selection intact; closing a running tab terminates and reaps exactly its four children.
- PTYs launch only after their views are attached and have a non-zero layout.
- The top-left position is the sole initial-focus pane, independent of CLI kind.
- The per-grid default working directory is `/Volumes/Extreme Pro/Documents/Work`, with home-directory fallback when unavailable.
- Every app launch checks Codex, Claude, Grok, Cursor Agent, and Hermes Agent; an official updater runs only when a newer release is reported. Cursor Agent's official update command performs its own check and installs only when needed.
- `~/.local/bin` is first in terminal `PATH`; its five canonical CLI names are atomically repaired and verified with `--version` on launch.
- An updater or discovery failure is non-blocking only when a provider-plausible previous launcher or the repaired alias verifies. Candidate targets are preflighted before replacement, every retained fallback is surfaced as a warning, and an alias failure blocks all terminal launch until Retry succeeds.
- Lifecycle cancellation stops the active updater process group and does not begin later updater commands.
- Hermes keeps an environment-sanitizing launcher so inherited `PYTHONHOME` or `PYTHONPATH` cannot break its managed virtual environment.
- AgentGrid does not edit shell profiles, credentials, or provider configuration during maintenance.
- The 32-point bottom usage strip displays every meaningful returned window's label and percentage in four equal provider columns, with at most two compact lines. Reset, last-updated, and failure detail remain in tooltip/accessibility text, and stale or unavailable providers have an explicit warning marker. Hermes is omitted because it routes through underlying providers.
- Codex publishes primary and secondary app-server windows; Claude publishes account and active named-model windows; Grok publishes included and enabled on-demand quotas through the installed CLI's canonical ACP billing exchange; Cursor publishes its two model pools or an explicitly applicable legacy monthly pool.
- Provider fetches are isolated and concurrent. Failed or omitted windows retain only their own last successful values as stale, while explicit removal clears obsolete windows. Expired Claude credentials skip the quota request, and a Claude usage 401 reports a sanitized instruction to run `/login` in Claude Code; AgentGrid does not refresh or mutate Claude-owned OAuth state. No credentials, raw responses, or quota history are logged or persisted.
- Usage refreshes at launch, every 60 seconds only while active, and after activation, wake, screen wake, and network recovery. Triggers coalesce and each failing provider independently backs off through 60, 120, 240, 480, and 900 seconds.
- Focus retention rejects bounded programmatic activation steals but disarms for explicit clicks, Command-Tab switches, and the one-shot **Allow Next App Switch** command. It uses modern cooperative activation and never `activateIgnoringOtherApps`.
- Accessibility preflight is quiet. Permission UI is user-initiated, and protected-file readiness appears only after a real required read returns `EPERM` or `EACCES`. Stable local releases use the fixed app path, Apple Development team `9UKJNG8B38`, hardened runtime, and no App Sandbox; macOS consent cannot be granted in code.
- The app does not restart exited agents or persist terminal state, working directories, prompts, or credentials.
- SwiftTerm is pinned to 1.20.0.
- All catalog icon sizes are generated from the approved master; never redraw them independently.

## Validation

Regenerate `AgentGrid.xcodeproj` after changing `project.yml` or adding source files. Use the `AgentGrid` scheme for macOS tests and builds. Runtime validation must confirm all five version checks, no updater invocation for current versions, updater invocation for an available version, direct success of every canonical alias, every real provider window/reset, 60-second foreground and lifecycle recovery behavior, provider/window stale isolation, explicit-switch-safe focus retention, permission readiness from actual denials, no Hermes quota segment, no terminal child before maintenance and grid launch, duplicate selection support, exact process arguments per grid, the permanent Work cwd, stable PIDs through tab switches, selected-grid input focus, four-child teardown without zombies, visible terminal output, and a non-fullscreen visible-frame window.
