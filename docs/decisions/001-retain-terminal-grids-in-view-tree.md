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

Use Design A. `GridTabsModel` is the public behavior seam for add, select, and close policy. `TerminalGridDeck` renders every open `TerminalGridView` as a stable peer in a `ZStack`; opacity, hit testing, and accessibility expose only the selected grid. `TerminalPane` receives active state and lets only the leading Codex terminal claim first responder on an inactive-to-active transition. On close, `ChildProcessReaper` waits for each exact child PID on a utility queue so an immediately dismantled SwiftTerm view cannot leave a zombie process.

This design preserves the existing, validated `NSViewRepresentable` creation and teardown behavior. It hides real tab policy without introducing an abstraction for an unproven alternate terminal backend.

## Consequences

- Hidden grids continue rendering terminal output and consuming the resources of four CLI processes; the six-grid cap makes that cost explicit and bounded.
- Switching tabs does not recreate or terminate PTYs.
- Closing a tab removes its retained view subtree, terminates exactly those four processes, and reaps them without blocking the UI.
- Focus transfer is a lifecycle concern in `TerminalPane`, not a repeated rule in tab buttons.
- Session persistence across app relaunch remains out of scope.
