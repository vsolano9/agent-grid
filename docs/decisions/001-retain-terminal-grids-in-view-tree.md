# ADR-001: Retain terminal grids in the SwiftUI view tree

## Status

Accepted

## Date

2026-08-22

## Context

Each AgentGrid tab represents four live SwiftTerm PTYs. A conditional selected-tab view would dismantle `NSViewRepresentable` terminals when the user switches tabs, which invokes the existing teardown path and terminates the processes. Tab selection must change presentation without changing session lifetime.

The module must own these invariants: one to six grids, stable identity for every open grid, monotonic names, one selected grid, session survival across selection, four-session teardown on close, and predictable focus transfer.

## Designs considered

| Criterion | A: Retained SwiftUI deck | B: AppKit terminal-session cache |
| --- | --- | --- |
| Caller model | `GridTabsModel` plus a selected ID | Session objects exposing cached terminal views |
| Hidden complexity | Tab policy and layered presentation | Tab policy, terminal construction, view reparenting, and PTY ownership |
| Owned invariants | Model owns count/naming/selection; deck owns retention | Session cache owns nearly all lifecycle |
| Dependency direction | UI model remains independent of SwiftTerm/AppKit | Tab model becomes coupled to AppKit and SwiftTerm |
| Failure semantics | Existing teardown runs only when a tab leaves the collection | New custom teardown and reparenting paths |
| Test seam | Pure model and activation-gate tests | AppKit-heavy lifecycle tests |
| Migration | Small extension of proven views | Replaces the proven representable lifecycle |
| Change locality | Tabs and focus stay in three focused modules | Terminal construction and tab policy change together |

## Decision

Use Design A. `GridTabsModel` is the public behavior seam for add, select, and close policy. `TerminalGridDeck` renders every open `TerminalGridView` as a stable peer in a `ZStack`; opacity, hit testing, accessibility, and AppKit visibility expose only the selected grid. `TerminalPane` receives active state and lets only the leading Codex terminal claim first responder on an inactive-to-active transition.

On close, `TerminalPane` starts one coalesced, awaitable cleanup task per pane. The repo-owned SwiftTerm `LocalProcess` remains the sole `waitpid` owner for the forkpty leader. AgentGrid snapshots descendant identities (PID, start time, UID, parent, and process group), signals the original group only while the leader identity still matches, and individually escalates still-matching descendants on a bounded utility task. This avoids racing the dependency's leader reap and avoids signaling an unrelated process after PID reuse.

This design preserves the existing, validated `NSViewRepresentable` creation and teardown behavior. It hides real tab policy without introducing an abstraction for an unproven alternate terminal backend.

## Consequences

- Hidden grids keep their four CLI processes and live PTYs, but their AppKit terminal views are hidden to suppress inactive redraw work; the six-grid cap makes the retained session cost explicit.
- Switching tabs does not recreate or terminate PTYs.
- Closing a tab removes its retained view subtree, starts bounded identity-safe teardown of each forkpty leader and every descendant observed before or during the grace interval, and exposes the result without blocking the UI. SwiftTerm reaps the four leaders; non-child descendants can only be observed to exit.
- macOS has no subreaper or process job object. A descendant that double-forks and reparents before the bounded snapshots observe it cannot be guaranteed by ancestry-based cleanup, so this design does not claim universal descendant ownership.
- Focus transfer is a lifecycle concern in `TerminalPane`, not a repeated rule in tab buttons.
- Session persistence across app relaunch remains out of scope.
