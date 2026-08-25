# ADR-002: Gate terminal launch on CLI maintenance

## Status

Accepted

## Date

2026-08-25

## Context

AgentGrid launches unrestricted CLI agents by absolute executable path. Finder launches provide a minimal environment, CLI installers use different stable and versioned locations, and an updater can replace a command between initial resolution and PTY startup. A current Claude installation demonstrated that package presence and a nominally current version do not prove the executable works.

The accepted behavior requires every app launch to attempt all five CLI updates and keep their canonical commands working.

## Decision

Run one app-owned maintenance transaction before constructing the terminal configuration. The transaction attempts all updates, independently rediscovers provider executables, atomically repairs `~/.local/bin` links, verifies each link with `--version`, and permits terminal setup only when one complete, unique report entry exists for all five commands. Each updater runs in an isolated process group so timeout or cancellation terminates its descendants as well as its root process.

Update transport failure and executable failure are separate states. An offline or updater failure can degrade to a warning when the existing canonical command still verifies. A missing or non-running command blocks terminal setup and exposes Retry.

## Alternatives considered

### Background update after workspace presentation

This minimizes perceived startup time, but a terminal can race with package replacement and the app can retain stale absolute paths. It cannot guarantee that aliases work before use.

### External scheduled maintenance

A launchd or scheduled updater separates concerns, but it does not prove maintenance ran for the current launch and introduces another mutable owner, schedule, and failure surface.

### Resolve commands through an interactive shell

This could observe shell aliases, but shell aliases are syntax rather than executable files, interactive startup can have unrelated side effects, and the four PTYs need stable executable paths. Canonical links are simpler and work in Finder and shell environments.

## Consequences

- App launch includes network and updater latency, displayed as explicit five-step progress.
- Terminal configuration always uses post-maintenance paths.
- `~/.local/bin` becomes AgentGrid's canonical executable seam for the five supported CLIs.
- Offline launch remains usable when the prior installations verify.
- A broken CLI cannot silently produce an error-only terminal pane; maintenance must repair it or remain on Retry.
- New supported CLIs require one catalog entry plus tests, without changing SwiftUI sequencing.
