# AgentGrid Multi-Grid Tabs Design

## Product decision

Add one compact tab strip below the macOS title bar. Each tab owns an independent four-terminal AgentGrid. Switching tabs preserves all four running PTYs, their output, and their state. Closing a tab terminates only that tab's four sessions. The app always keeps at least one grid and limits the window to six grids so the utility remains lightweight and cannot quietly fan out beyond 24 unrestricted CLI processes.

## Reference ledger

- User Notepad++ screenshot — hierarchy and state language: horizontal document tabs, dark active surface, warm top accent, close affordance.
- Current AgentGrid screenshots — product truth: standard macOS title bar, maximized visible-frame window, strict 2×2 terminal surface, no sidebar or secondary chrome.
- Photomator App Store reference (private reference only) — material and interaction job: compact professional dark controls, restrained elevation, and crisp separation.
- Generated concept board: `agent-grid-tabs-concept.png` — implementation candidate and four-state motion storyboard. SHA-256: `528bb6109c7b84b8179b6f1e6be2c22f1eeab734c6dd8dd8d59ff93c22094757`.

The references contribute distinct properties only. The final layout, symbols, labels, sizing, state model, and behavior are original to AgentGrid.

## Dynamic design contract

- Experience thesis: multiple autonomous four-agent workspaces remain one calm, terminal-first command surface.
- Signature moment: a new tab enters eight points from the right while the three-point orange selection edge settles onto it.
- Depth tier: Tier 1. Near-black and graphite layers, one-pixel separators, no glass, gradient, bloom, or ornamental depth.
- Motion language: 140 ms ease-out for add, select, hover, and close state changes; no continuous animation.
- Reduced motion: state changes are immediate while selection remains equally clear through contrast, weight, and the orange top edge.
- Performance budget: all hidden grids stay mounted by design, so creation is capped at six grids; the tab strip itself performs no continuous work.

## Layout and states

- Strip height: 39 points, directly above the terminal grid.
- Tab width: 128–176 points; horizontal scrolling preserves labels when space is constrained.
- Active tab: graphite fill, semibold label, three-point orange top edge, visible close button when more than one tab exists.
- Inactive tab: darker fill, secondary label, close button revealed only on hover.
- Add button: 39-point square after the final tab, disabled at six grids.
- Each tab uses a four-square system symbol and a short monotonic label (`Grid 1`, `Grid 2`, and so on).
- `⌘T` creates and selects a grid. `⌘1` through `⌘6` select visible grids. Close buttons terminate individual grids; standard `⌘W` retains its macOS window-close behavior.

## Accessibility and lifecycle

- All interactions use native `Button` controls with labels, hints, tooltips, keyboard shortcuts, selected traits, and a contained “Agent grids” accessibility group.
- Hidden terminal grids are excluded from accessibility and hit testing but remain attached and laid out so their PTYs continue running.
- Selecting a grid transfers first-responder focus to its Codex terminal once, without stealing focus during ordinary redraws.
- Closing the selected grid activates the tab that moves into its slot, or the preceding tab when the closed tab was last.
