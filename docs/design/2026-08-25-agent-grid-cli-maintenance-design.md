# AgentGrid CLI maintenance design

## Outcome

AgentGrid checks Codex, Claude, Grok, Cursor Agent, and Hermes Agent every time the app opens, but installs only when the provider reports a newer release. It then repairs the stable executable links in `~/.local/bin`, verifies every link with the CLI's `--version` command, and only then builds the terminal launch catalog.

An update failure does not discard a working installation. If the stable link still passes verification, AgentGrid opens the grid setup with a visible warning. If any link cannot launch, the maintenance screen names that CLI and offers Retry; terminal setup remains unavailable so a grid cannot start with a known-broken command.

## Verified trigger

The installed AgentGrid 1.2.0 resolves its launch catalog once during app initialization and performs no maintenance. On 2026-08-25, Codex, Grok, and Cursor Agent passed `--version`; Claude's npm package was current at 2.1.245 but its launcher failed because the package's native binary was missing. `~/.local/bin` was already first in both zsh startup files and AgentGrid's terminal environment, but it had no `claude` link.

Hermes Agent was not installed when it was added to scope. The official Nous Research macOS installer completed into `~/.hermes/hermes-agent`, created `~/.local/bin/hermes`, and verified Hermes Agent 0.20.5 before implementation continued.

Official owner documentation provides these update seams:

- Codex: `codex update`; npm-managed installations can be refreshed with `npm install -g @openai/codex@latest`.
- Claude Code: `claude update`; npm-managed installations can be refreshed with `npm install -g @anthropic-ai/claude-code@latest`. AgentGrid grants that package's postinstall script for the single npm invocation so npm's `allowScripts` protection cannot leave the native binary stub in place.
- Grok: `grok update`.
- Cursor Agent: `cursor-agent update` or `cursor-agent upgrade`.
- Hermes Agent: `hermes update --yes`.

## Architecture

`CLIMaintenanceService` owns the complete transaction: resolve and verify the current executable, choose the version-check mechanism, run checks in deterministic sequence, invoke the updater only for an available version, repair each canonical link, verify every link, and return one report. Its public interface exposes a single asynchronous maintenance operation; SwiftUI does not know package names, filesystem mechanics, process arguments, or fallback policy.

`CLICommandRunner` is an actor that starts every command in its own POSIX process group. It polls cooperatively, terminates the complete group on cancellation or timeout, discards updater output, and captures only bounded version output. No process handle, pipe, or mutable runner state crosses an actor boundary.

`CLIExecutableLocator` discovers each provider independently of `~/.local/bin`, including Grok's stable launcher, the newest installed Cursor Agent version, and Hermes Agent's managed virtual environment. `CanonicalCLIAliasStore` never trusts an existing canonical executable as proof of identity: it preflights the discovered provider candidate, rejects link chains that depend on the destination alias, refuses to replace a directory, and uses an atomic rename so terminals never observe a half-written launcher. When discovery or candidate validation fails, a provider-plausible previous symlink remains available only when it still passes `--version`; the repair result records fallback use so the UI always reports a warning even if the updater itself exited successfully. Stable provider links remain indirect rather than being pinned to their current version target.

Hermes is the one canonical regular launcher rather than a symlink. AgentGrid preserves Nous Research's official launcher when it verifies, or atomically recreates an equivalent wrapper that unsets `PYTHONHOME` and `PYTHONPATH` before entering the managed virtual environment. Maintenance also removes those variables from updater subprocesses. This retains the installer's environment-isolation contract while still repairing a missing Hermes command.

`CLIMaintenanceModel` is main-actor UI state. `AgentGridApp` starts its task once, renders an inline maintenance surface while work is active, and constructs `AgentGridConfiguration.live()` only from a launchable report. Retry performs a fresh complete pass. A warning is shown in the setup surface without a startup alert, following Apple's guidance to keep launch problems contextual and actionable.

## Design-twice comparison

| Criterion | Deep maintenance service | SwiftUI invokes direct updater helpers |
| --- | --- | --- |
| Caller model | One `perform()` result | Five commands plus alias and retry coordination |
| Hidden complexity | Package-manager detection, ordering, timeouts, links, verification, fallback | Most policy leaks into the app and view model |
| Owned invariants | Every version checked; only newer versions installed; launch only when all aliases verify | Callers must preserve ordering and completeness |
| Dependency direction | UI depends on a domain report; adapters depend on Foundation | UI depends directly on process and filesystem mechanisms |
| Failure semantics | Per-CLI update warning versus broken alias is explicit | Partial failure interpretation is scattered |
| Test seam | One behavior-level service seam plus real adapter tests | Mostly shallow helper tests |
| Change locality | New CLI/update rule changes one catalog/service area | Changes touch the app, model, and helper calls |

The deep service is selected because the sequencing and fallback rules are the feature. A fire-and-forget updater was rejected because a PTY could launch while its executable was being replaced. A scheduled or launchd updater was rejected because it would not prove maintenance occurred on each AgentGrid launch.

## Update and alias policy

- All five checks run serially. Codex and Claude can share one global npm prefix, so any necessary package replacement remains serialized; one deterministic sequence also makes status and recovery clear.
- npm registry versions gate npm-managed Codex and Claude installs. Grok's JSON check and Hermes's text check gate their native updaters. Cursor Agent's native update command is self-checking and runs exactly once.
- npm-managed Codex and Claude installations use their official npm packages. The Claude invocation grants only `@anthropic-ai/claude-code` lifecycle scripts and does not persist npm configuration. Other working installations use their CLI-native update command.
- Grok, Cursor Agent, and Hermes Agent use their native update commands.
- A failed update is a warning when the post-update canonical alias still passes `--version`.
- Missing or failing aliases are blocking. Retry reruns all five checks rather than only the visible failure, preserving the every-launch verification contract.
- Window/task cancellation terminates the active updater group and stops the transaction before any later updater begins; a subsequent launch starts a fresh complete transaction.
- AgentGrid never edits shell startup files, authentication stores, CLI configuration, or credentials. The existing terminal environment already places `~/.local/bin` first.
- Subprocesses receive the maintained terminal environment, no shell interpolation, no prompts, a bounded timeout, and an isolated process group that is fully terminated on timeout or cancellation.

## Interface and accessibility

The maintenance surface reuses AgentGrid's centered graphite setup layer, orange accent, native controls, and existing typography. Five fixed rows show pending, checking, updating, verifying, warning, or failed state. A determinate `ProgressView` reports completed CLI checks out of five. Failure copy names the CLI and action; Retry is the only required recovery control. VoiceOver receives the maintenance title, progress value, row state, and retry hint. Reduce Motion requires no special branch because only native progress animation is used.

The workspace adds a 42-point graphite quota rail below the terminal deck. Five equal segments preserve the grid rhythm, use monospaced percentage values, and animate only the thin orange fill. Codex displays a real account-wide remaining percentage from its authenticated local app-server protocol. Providers without a safe comparable CLI value show an em dash and explanatory tooltip; session tokens, API billing, and fabricated estimates are deliberately excluded. The trailing refresh control is icon-only with a descriptive accessibility label, and Reduce Motion makes percentage changes immediate.

References inspected before implementation:

- Existing `GridSetupView` and approved AgentGrid setup design for hierarchy and materials.
- Apple Human Interface Guidelines, Progress indicators, for consistent, accurate progress and useful stalled-state feedback.
- Apple Human Interface Guidelines, Alerts, for contextual startup error presentation instead of a launch alert.

## Proof and rollout

- Tests fail first for catalog commands, complete update attempts after failure, warning-versus-blocking classification, atomic alias repair, timeout/cancellation, and main-actor retry state.
- Focused maintenance tests, the complete AgentGrid suite, Debug build, Release build, generated-project drift, and app-icon verification pass.
- Runtime proof uses disposable fake CLI installations for update/alias behavior, then the real installed CLIs for `--version` and canonical-link resolution.
- Manual launch inspection covers progress, warning/failure recovery, setup transition, and terminal launch after maintenance.
- Ship the amendment as AgentGrid 1.3.1 build 5. Install the verified Release bundle at `/Users/victor/Applications/AgentGrid.app`, launch it twice, verify the first launch installs only an actually available release, and verify the second launch performs checks without unnecessary installs.
