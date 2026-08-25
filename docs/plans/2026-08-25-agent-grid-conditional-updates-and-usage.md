# AgentGrid conditional CLI updates and usage rail plan

**Goal:** Preserve every-launch CLI and alias verification without reinstalling current versions, and add a compact, truthful provider-usage rail to the workspace.

## Acceptance contract

- Check all five supported CLIs during launch in catalog order.
- Run an updater only when its official check reports a newer version. Invoke Cursor Agent's self-checking updater exactly once.
- Repair and verify all five canonical aliases on every launch; a broken alias still blocks terminal creation.
- Label Checking, Updating, and Verifying accurately in the startup surface.
- Show a real remaining percentage only when a provider exposes a safe comparable account-wide reading. Show an explicit unavailable state for unsupported providers.
- Keep quota reads local, ephemeral, and independent of terminal session lifecycle.
- Pass focused and complete tests, Debug and Release builds, generated-project drift checks, live two-launch updater proof, alias checks, installed-app postflight, and manual visual inspection.

## Implementation slices

1. Extend maintenance catalog entries with provider-specific check commands and output formats. Add service tests for current, newer, malformed, native self-checking, failure, cancellation, and alias fallback paths.
2. Add a main-actor usage model, local Codex app-server reader, bounded response parser, honest provider capability map, compact SwiftUI rail, refresh action, accessibility labels, and Reduce Motion behavior.
3. Amend owner and user documentation, bump to 1.3.1 build 5, regenerate the project deterministically, and validate the complete app.
4. Install the verified Release bundle, inspect the maintenance and usage surfaces, prove repeated launch does not reinstall current CLIs, then commit, push, merge, and verify remote equality.
