# AgentGrid App Icon Implementation Plan

> **For the executor:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Ship a polished generated AgentGrid app icon in every required macOS size without changing app behavior.

**Architecture:** A generated 1024 px master is the only creative production source. The existing deterministic Swift generator converts that approved master into the complete asset-catalog set, Xcode compiles it into the Release bundle, and the installed app is verified through the macOS owner surfaces.

**Tech Stack:** Built-in image generation, PNG, Swift/CoreGraphics generator, Xcode asset catalogs, XcodeBuildMCP, macOS LaunchServices.

---

## Constraints and ownership

- Writer: this worktree owns the AgentGrid repository and installed AgentGrid bundle for this task.
- Preserve the exact product layout, CLI commands, YOLO flags, working-directory behavior, and bundle identifier.
- Do not publish reference-library files or runtime screenshots.
- Keep generated design evidence and the final master in the repository; remove discarded temporary outputs.

## Task 1: Produce the final master

**Create:** `docs/design/agent-grid-icon-direction.png`, `docs/design/agent-grid-icon-master.png`

1. Inspect the generated direction board and record keep/change/reject decisions in the design document.
2. Generate one final 1024×1024 icon using the approved direction.
3. Inspect native resolution, alpha edges, symmetry, contrast, and small-size silhouette.
4. Regenerate once with a targeted correction if any production criterion fails.

## Task 2: Derive and validate the asset set

**Modify:** `Resources/Assets.xcassets/AppIcon.appiconset/*.png`, `scripts/generate-app-icon.swift`

1. Update the generator to consume the approved master and deterministically emit all catalog sizes.
2. Run the generator and verify exact dimensions, alpha/color profile, filenames, and `Contents.json` coverage.
3. Create a contact sheet showing 1024, 512, 256, 128, 64, 32, and 16 px outputs at useful inspection scale.

## Task 3: Build and owner-surface verification

1. Run all 12 existing tests with XcodeBuildMCP; expect zero failures.
2. Build Release with XcodeBuildMCP; expect success with no new warnings.
3. Inspect the compiled `.icns` and code signature.
4. Replace `~/Applications/AgentGrid.app`, relaunch it, and confirm the installed icon in Finder or Dock.
5. Confirm the normal maximized window and four exact YOLO child commands remain intact.

## Task 4: Review and delivery

1. Review every changed file and the complete diff; scan for secrets, placeholders, reference-library files, and unnecessary large assets.
2. Update README/context only if the asset workflow needs durable documentation.
3. Commit the logical icon change, merge to `main`, push `origin/main`, and verify the remote commit.
4. Remove the worktree and task-created build/contact-sheet residue after evidence is recorded.

## Rollback and stop condition

Rollback is the prior icon set at commit `8ea0063`. Stop only when the final image is visually approved against the design record, every required size and compiled asset are verified, tests and Release build pass, the installed app shows the new icon while all four terminals remain healthy, the public remote matches local `main`, and task residue is cleaned.
