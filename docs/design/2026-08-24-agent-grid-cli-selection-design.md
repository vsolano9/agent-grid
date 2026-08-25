# AgentGrid Per-Grid CLI Selection Design

## Outcome

AgentGrid shows a four-slot CLI setup surface for Grid 1 on every app launch and for every grid created with `+` or `⌘T`. Each slot independently selects Codex, Claude, Grok, Cursor Agent, or Hermes Agent, so duplicate combinations such as four Codex sessions are valid. Each draft also chooses its own working directory, with Work as the default. Terminals start only after the user activates the grid.

The default terminal working directory remains `/Volumes/Extreme Pro/Documents/Work`, while a native folder chooser allows a different directory per grid before launch. This change does not add settings, persistence, telemetry, credentials, or app-owned services.

## Product decisions

- Every new grid starts as an unlaunched draft with useful defaults: Codex, Claude, Grok, and Cursor Agent in 2×2 reading order.
- Four native pop-up selectors correspond to Top Left, Top Right, Bottom Left, and Bottom Right. Each selector is independent and permits the same CLI as every other selector.
- Every draft starts at the Work root and exposes `Change…` through the native macOS folder chooser. New grids do not inherit another grid's custom folder.
- `Launch Grid N` freezes that grid's ordered CLI selection and working directory, then mounts exactly four SwiftTerm panes. A running grid cannot be reconfigured in place because that would terminate live PTYs.
- Switching among draft and running grids preserves each draft selection and every mounted PTY.
- The existing six-grid cap, monotonic names, close behavior, and `/Work` fallback policy remain unchanged.
- Focus belongs to the top-left pane by position, not to every pane whose selected kind happens to be Codex.

## Architecture and data flow

`AgentGridSelection` is the fixed four-slot value contract. `AgentGridTab` owns draft and launched CLI selections plus draft and launched working-directory values. `GridTabsModel` owns updates and the one-way draft-to-launched transition; it ignores edits after launch.

`AgentGridConfiguration` remains the live executable/environment catalog. It resolves one launch spec per available CLI once, then expands a grid's ordered selection into four specs, including duplicates, applying the frozen grid directory to every spec. `TerminalGridDeck` mounts only launched tabs and continues retaining them by stable tab ID. The workspace view shows `GridSetupView` only when the selected tab is still a draft.

## Interaction and visual contract

- Experience thesis: four explicit launch choices turn an unrestricted terminal fan-out into a deliberate, readable grid recipe without adding permanent chrome.
- Signature moment: the setup surface resolves into the same spatial 2×2 grid after launch; 140 ms restrained opacity and scale preserve location. Reduce Motion swaps immediately with no transform.
- Depth tier: Tier 1. Near-black background, one centered graphite setup layer, native control surfaces, and hairline separation; no glass, gradients, bloom, or ornamental shadows.
- State coverage: draft default, draft duplicates, selector hover/focus/open/selected, launch pressed, launched, tab switch, draft close, running close, six-grid add disabled, missing CLI terminal error, and Reduce Motion.
- Performance budget: no continuous animation or background work; setup adds no process before launch; running-grid cap remains 24 child processes.

The generated internal direction board is `agent-grid-cli-selection-concept.png` (SHA-256 `3fc0bb7867221f4215ffe416908a34f33cedacd5e5a437eb3f44c44e26b327b5`). Keep the centered hierarchy, four labeled selectors, visible Work path, and launch action. Reject its generated terminal headers/status marks; production terminals remain raw SwiftTerm surfaces.

## Reference ledger

- Existing `agent-grid-tabs-concept.png` — product truth and interface hierarchy: title bar, compact tabs, strict 2×2 terminal geometry, orange selection edge.
- Shared `desktop-ui-raycast.png` — interface hierarchy only: focused central task with sparse surrounding chrome; no brand, logo, color, or composition copying.
- Shared `product-ui-linear-refresh.png` — material/lighting only: hairline structure and quiet near-black depth; no brand or component copying.
- [Apple HIG: Pop-up buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons) — flat mutually exclusive choices, contextual labels, and useful defaults.
- [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion) — brief, purposeful, optional, cancellable feedback.

## Proof and rollout

- Unit tests must fail first for duplicate catalog expansion, draft/launch state, new-grid setup, post-launch immutability, and position-based focus.
- The complete macOS test suite, Debug build, Release build, generated-project drift check, and runtime process inspection must pass.
- Manual visual inspection must cover first launch, four Codex selection, launch, new-grid setup, tab switching, and Reduce Motion.
- The update is compatible with existing terminal behavior because no terminal or persisted data exists before a grid launches, and AgentGrid intentionally persists no sessions across app relaunch.
