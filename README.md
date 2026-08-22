# AgentGrid

AgentGrid is a lightweight native macOS app that opens four real terminal sessions in one maximized 2×2 window:

| Position | CLI | Auto-approval mode |
| --- | --- | --- |
| Top left | Codex | `--dangerously-bypass-approvals-and-sandbox` |
| Top right | Claude | `--dangerously-skip-permissions` |
| Bottom left | Grok | `--always-approve` |
| Bottom right | Cursor Agent | `--yolo` |

There are no tabs, sidebars, pane headers, settings, or app-owned services. Closing AgentGrid terminates the four PTYs and their child processes.

## Requirements

- macOS 15 or newer
- Xcode 26 or newer to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- The `codex`, `claude`, `grok`, and `cursor-agent` CLIs installed and authenticated

The app searches the inherited `PATH` plus common Homebrew and user CLI folders. A missing command produces a normal `env` error inside only that pane.

## Working directory

Every terminal starts in:

```text
/Volumes/Extreme Pro/Documents/Work
```

If that folder is unavailable, AgentGrid falls back to the current user's home directory. macOS asks for removable-volume access the first time this external-volume folder is used; choose **Allow** to keep the Work directory as the terminal root.

## Build and test

```bash
xcodegen generate
xcodebuild -project AgentGrid.xcodeproj -scheme AgentGrid -configuration Debug test
```

Regenerate the complete macOS icon set from the approved 1024 px master with:

```bash
swift scripts/generate-app-icon.swift \
  docs/design/agent-grid-icon-master.png \
  Resources/Assets.xcassets/AppIcon.appiconset
```

After a Release build, verify that Xcode compiled the icon and asset catalog:

```bash
scripts/verify-app-icon.sh /path/to/AgentGrid.app
```

The generated Xcode project pins [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) to version 1.20.0. CI is intentionally local-only.

## Safety

All four agents start in their unrestricted/auto-approval modes. They can execute commands and modify files without asking for confirmation. AgentGrid itself stores no credentials, history, prompts, or telemetry.

## License

MIT
