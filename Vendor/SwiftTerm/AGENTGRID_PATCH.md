# AgentGrid SwiftTerm patch

This directory is a source snapshot of SwiftTerm 1.20.0 at upstream commit
`5d14406844143538cd8f8851d2d8a67c1fe443e5`. The upstream MIT license remains
in `LICENSE` and is also reproduced in AgentGrid's `THIRD_PARTY_NOTICES.md`.

AgentGrid carries a narrow Kitty graphics allocation-safety patch because
SwiftTerm 1.20.0's cache option evicts retained images only after APC parsing,
multi-chunk accumulation, base64 decoding, decompression, and pixel allocation.
The patch adds a default-compatible per-transfer option and enforces it before
each of those allocation boundaries. Tests live in
`Tests/SwiftTermTests/KittyPayloadLimitTests.swift`.

AgentGrid also carries a local-process termination patch. SwiftTerm remains the
sole owner of `waitpid` for its forkpty leader, publishes an awaitable result
only after reaping, and retries interrupted waits before canceling its process
monitor. The injected-interruption regression lives in
`Tests/SwiftTermTests/LocalProcessTerminationTests.swift`.

The package manifest also omits SwiftTerm's unused DocC command-plugin
dependency. AgentGrid does not build documentation through the vendored
package, and omitting that unused dependency keeps application resolution to
the runtime packages the source actually imports.

When updating SwiftTerm, compare the upstream Kitty/APC and LocalProcess
implementations with this patch and retain the adversarial tests before
changing the pinned commit.
