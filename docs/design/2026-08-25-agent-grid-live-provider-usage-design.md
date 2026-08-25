# AgentGrid Live Provider Usage Design

## Outcome

The bottom rail shows one real percentage remaining for Codex, Claude, Grok, and Cursor. Hermes remains a selectable and maintained terminal CLI, but it does not appear in the rail because its account quota belongs to its routed provider.

The rail reads the authenticated sessions already owned by the four CLIs or desktop apps. It stores no credentials, sends no telemetry, and preserves the most recent successful in-memory reading when a later refresh fails.

## Verified provider seams

| Provider | Local credential owner | Usage source | Normalized value |
| --- | --- | --- | --- |
| Codex | `~/.local/bin/codex` | `codex app-server --stdio`, `account/rateLimits/read` | Primary window remaining |
| Claude | Claude Code credentials file or macOS Keychain item `Claude Code-credentials` | `GET https://api.anthropic.com/api/oauth/usage` | Remaining value of the most constrained active quota window |
| Grok | `~/.grok/auth.json` | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` | Billing-period credit remaining |
| Cursor | Cursor.app `state.vscdb`, key `cursorAuth/accessToken` | `GET https://cursor.com/api/usage-summary` | Cursor plan allowance remaining |

Live read-only probes on 2026-08-25 confirmed that all four owner surfaces return parseable usage for the configured accounts. Provider endpoints are not public stability contracts, so every reader is isolated, bounded, and fail-soft.

## Architecture choice

### Selected: native provider readers behind one coordinator

AgentGrid owns a small reader for each provider, a shared bounded HTTP transport, and one actor that concurrently refreshes the four readers. The coordinator is the only caller-facing surface and owns last-good in-memory values, stale-state translation, ordering, and failure isolation.

This hides credential formats and vendor response volatility from the SwiftUI model. A provider response can change without coordinated UI edits, and tests can replace each credential and HTTP boundary independently.

### Rejected: require the CodexBar executable at runtime

CodexBar already implements the provider integrations, but invoking it would add an undeclared sixth CLI dependency to a utility whose launch gate currently owns five CLIs. Its configuration, enabled-provider state, release cadence, and installation could make AgentGrid's rail fail even when the underlying provider sessions are healthy.

The native readers use CodexBar's MIT-licensed implementation and provider documentation as a reference. AgentGrid includes the applicable attribution notice.

## Data and failure behavior

- `CLIUsageService` displays exactly `[Codex, Claude, Grok, Cursor]` and fetches them concurrently.
- Each successful response becomes a bounded integer from 0 through 100.
- Claude selects the highest used percentage across active account-wide and model-scoped windows, so the single compact number warns about the nearest limit instead of hiding it.
- Cursor follows the dashboard precedence: `totalPercentUsed`, both lane percentages, one lane percentage, then a finite usage/limit ratio.
- A failed first read shows an em dash with an actionable provider-specific reason.
- A failed later read keeps the last successful percentage as visibly stale and explains that state in the tooltip and accessibility label.
- Refresh cancellation cancels outstanding URL requests. No reader failure prevents another provider from updating.

## Credential and privacy behavior

- Credentials are read only at refresh time and retained only in local variables for the request lifetime.
- Claude prefers the configured credentials file and falls back to the existing Claude Code Keychain item. AgentGrid never refreshes, rewrites, or exports Claude credentials.
- Grok reads the preferred OAuth entry from the existing auth map and never writes it.
- Cursor opens its SQLite database read-only, includes live WAL state, and never copies or alters the database.
- Authorization headers, cookies, tokens, raw responses, and credential payloads are never logged, persisted, surfaced in errors, or included in tests.
- Network requests go only to the provider-owned HTTPS origins listed above and use short timeouts.

## User interface

The existing 42-point bottom rail, typography, progress line, refresh action, and Reduce Motion behavior remain unchanged. Removing Hermes gives the four comparable account quotas equal width. Fresh values retain the orange indicator; stale values remain readable with reduced emphasis and an explanatory tooltip.

## Validation

- Parser tests cover clamping, alternate payloads, missing data, malformed data, and provider selection precedence.
- Credential tests use synthetic tokens and temporary files or SQLite databases; no live secrets enter fixtures or logs.
- Service tests prove exact four-provider ordering, concurrent failure isolation, and last-good stale fallback.
- Full tests, Debug and Release builds, generated-project drift, license scan, live provider reads, installed-app runtime inspection, and manual visual/accessibility inspection must pass.

## References

- [CodexBar](https://github.com/steipete/CodexBar), MIT license.
- [CodexBar Claude provider](https://github.com/steipete/CodexBar/blob/main/docs/claude.md).
- [CodexBar Cursor provider](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md).
- [CodexBar Grok provider](https://github.com/steipete/CodexBar/blob/main/docs/grok.md).
