# Changelog

All notable changes to AgentGrid are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases before 1.4.0
are recorded only in the Git history.

## [Unreleased]

### Changed

- Release signing reads its identity and team from an untracked
  `Config/Local.xcconfig` (template: `Config/Local.xcconfig.example`). Without
  it, a plain Release build is signed ad hoc, so the README build command needs
  no signing overrides.
- The local release scripts take the identity they accept from the same file
  and refuse to run without one. They install to `~/Applications/AgentGrid.app`
  unless `AGENTGRID_INSTALL_PATH` names another path.

## [1.4.0] - 2026-10-16

### Changed

- New grids start in the last folder chosen with `Change…`, and that choice is
  remembered across relaunches. Before any choice, or when the saved folder is
  missing at launch, new grids start in your home folder. This replaces the
  fixed default folder of earlier builds; choose your usual folder once after
  updating.
- Hermes Agent updates are reported but never installed by AgentGrid, so a
  managed or customized Hermes checkout stays under its owner's control.
- The README documents a Release build and install that work with any signing
  setup.

### Fixed

- AgentGrid recovers focus when an automated browser launch takes it, including
  slow launches.
- Claude account usage windows that report reset text are kept in the usage
  strip.
- Terminal memory is bounded and closing a running grid cleans up its processes,
  including descendants that escape their process group.
- Startup maintenance recognizes Codex's standalone installation under
  `~/.codex/packages/standalone/current/` when it resolves the Codex updater.

### Removed

- The unused sample Mac and iOS apps from the vendored SwiftTerm snapshot, which
  carried outdated package pins.
