# AgentGrid Usage, Focus, and Permission Orchestration Design

## Outcome

AgentGrid 1.3.4 replaces its one-number, one-shot usage rail with a live four-provider monitor. It displays every meaningful quota window exposed by Codex, Claude, Grok, and Cursor and retains reset times for tooltip and accessibility detail. Readings refresh every 60 seconds while AgentGrid is in the foreground and immediately on launch, activation, wake, and network recovery. A failure preserves only the affected provider/window as stale while independent windows continue to update.

Grok usage is read through the authenticated Grok Build ACP process, not by copying a bearer token from `~/.grok/auth.json`. App-level focus retention allows a deliberate user switch but requests AgentGrid back after another process activates an app without a preceding user-switch gesture.

The local Release app is signed with one stable Apple Development team identity and is always installed at `~/Applications/AgentGrid.app`. This gives macOS a durable code identity across updates. AgentGrid preflights and reports protected access that it actually uses; it does not modify the TCC database, invent grants, or request camera, microphone, location, screen-recording, or other unused capabilities.

This document supersedes `2026-08-25-agent-grid-live-provider-usage-design.md` where the two conflict. Hermes remains a selectable and maintained terminal CLI but is not a usage provider because its quota belongs to whichever provider it routes through. Hermes configuration and plugin behavior are out of scope.

## Current evidence and constraints

- `ProviderQuotaReading.fetchRemainingPercent()` returns one `Int`; `CLIUsageState` and `CLIUsageEntry` therefore cannot preserve parallel quota windows, reset timestamps, or distinct stale states.
- `CLIUsageModel.start()` performs one launch fetch. There is no foreground timer, lifecycle recovery, network recovery, coalescing, or retry policy.
- Codex currently parses only `rateLimits.primary.usedPercent`, although the app-server response supplies primary and secondary windows with `windowDurationMins` and `resetsAt`.
- Claude currently collapses five-hour, seven-day, and model-specific limits to the most constrained percentage.
- Cursor currently collapses its monthly usage payload to one percentage and discards its billing-cycle dates. Cursor's current official product contract has two monthly pools.
- Grok currently reads an OAuth bearer from disk and calls the CLI proxy directly. That token can expire while the CLI's authenticated session remains recoverable.
- `TerminalPane` protects only first-responder ownership inside AgentGrid. `WindowMaximizer` makes the window key once; there is no app-level activation policy.
- The installed 1.3.3 build is ad-hoc signed, has no team identifier, and is rejected by `spctl`. The project has automatic signing but no `DEVELOPMENT_TEAM`. The keychain contains the valid identity `Apple Development: <maintainer email> (<label>)`. Certificate inspection establishes `OU=<team ID>`, which is the code-sign TeamIdentifier; `<label>` is only part of the identity label and must not be treated as the team.
- App Sandbox is already off and the hardened runtime is on. Those constraints must remain so the four PTYs can run unrestricted local tools, files, subprocesses, and network clients.

OpenAI documents that Codex has multiple allowances and reset times; the official app-server method exposes primary and secondary windows and their durations/resets. Anthropic documents five-hour and weekly limits, with additional model/feature caps possible. Cursor documents two usage pools on the monthly billing cycle. xAI documents a weekly usage pool and reset, and the Grok Build source exposes its authenticated billing configuration over ACP. The domain must therefore be dynamic instead of assuming one or two fixed rows.

## Design twice: data and UI boundary

### Approach A — flatten quota windows into independent rail cards

Each parser could emit a global `[QuotaWindow]`, with identity composed from provider and array index, and the rail could render every item as an equal-width card.

Advantages:

- Small initial diff from the current one-segment-per-provider rail.
- A single `ForEach` is simple.

Costs:

- Provider identity, ordering, error state, and retry policy leak into the view.
- Index identity is unstable when a provider adds or removes a window.
- One provider with three windows crowds out providers with one window.
- A provider failure has no natural home when it has no previous window.
- Per-window stale merge logic becomes distributed across parser, service, model, and view.

### Approach B — provider snapshots containing stable semantic windows

Each provider reader emits an observation for one provider. The coordinator merges it into a `ProviderUsageSnapshot` whose quota rows have semantic IDs, display metadata, reset time, and freshness. SwiftUI renders four equal provider columns, each containing its own compact vertical rows.

Advantages:

- The deep module hides provider response shapes, merge rules, retry state, and ordering.
- `ForEach` identity is stable when dynamic model-specific windows appear or disappear.
- Failure isolation matches the provider boundary while freshness remains per window.
- Four-provider visual balance is retained regardless of window count.
- Provider-level loading/unavailable state remains expressible before any window exists.

Costs:

- Requires a deliberate domain migration instead of extending the existing enum.
- The rail grows vertically to the maximum current window count.

### Selection

Approach B is selected. It concentrates volatility in provider adapters, keeps orchestration out of SwiftUI, and preserves stable identity and independent state. The bottom rail remains visually secondary as a fixed 32-point status strip with at most two compact lines. Four equal columns remain readable in the existing 800-point minimum window width.

## Provider snapshot contract

The public usage domain is value-based, `Equatable`, and `Sendable`:

```swift
struct ProviderUsageSnapshot: Identifiable, Sendable {
    let provider: AgentKind
    let state: ProviderSnapshotState
    let windows: [ProviderUsageWindow]
    let fetchedAt: Date?
    var id: AgentKind { provider }
}

struct ProviderUsageWindow: Identifiable, Sendable {
    let id: ProviderUsageWindowID
    let label: String
    let remainingPercent: Int
    let resetsAt: Date?
    let freshness: ProviderUsageFreshness
}
```

`ProviderUsageWindowID` is a provider plus a semantic provider-owned key, never an array index or display label. Examples are `codex.primary`, `codex.secondary`, `claude.five_hour`, `claude.seven_day`, `claude.model.<server-key>`, `grok.included`, `grok.on_demand`, `cursor.cursor_models`, and `cursor.other_models`.

`ProviderSnapshotState` covers loading, available, stale, and unavailable at the provider boundary. `ProviderUsageFreshness` carries fresh or stale plus a sanitized reason and the last successful fetch time. Percentages are clamped to 0...100 only at the parser boundary. Reset timestamps remain `Date` values until the view formats them in the user's current locale and time zone.

Readers return a `ProviderUsageObservation`, not a ready-to-render snapshot. An observation contains:

- successful windows;
- semantic IDs explicitly absent/inactive in the authoritative payload;
- semantic IDs that were expected but could not be parsed; and
- a sanitized provider diagnostic.

This distinction makes stale behavior precise:

- A successful window replaces its prior value and becomes fresh.
- An explicitly null or inactive window is removed; obsolete data is not kept stale.
- A known window whose field is missing/malformed keeps only its own last-good value as stale.
- A transport, authentication, timeout, or process failure keeps every last-good window for that provider stale while other providers update.
- A first failure with no last-good windows shows one provider-level unavailable row.
- Unknown new windows are admitted when the provider adapter can supply a stable server key, a percentage, and meaningful label. Unidentifiable fragments are ignored and diagnosed rather than assigned unstable identity.
- Snapshots remain in memory only. Relaunch starts at loading and never presents yesterday's quota as current.

## Provider translations

### Codex

`CodexUsageReader` continues to use `codex app-server --stdio` and `account/rateLimits/read`, but the parser preserves both `primary` and `secondary`, `usedPercent`, `windowDurationMins`, and `resetsAt`. Duration supplies the label: five-hour and 10,080-minute windows become `5 hr` and `Weekly`; other durations use a compact hour/day label. Explicit `null` removes that window. The app-server's sparse notification stream is not needed because the 60-second snapshot read is authoritative and keeps process lifetime bounded.

### Claude

`ClaudeUsageReader` keeps its bounded OAuth usage request and Claude's credential ownership. It emits the five-hour, seven-day, active model/feature windows, and any named active items in `limits`. Server keys, not translated labels, form IDs. Utilization is converted independently per item and each reset timestamp is retained. Explicit null/inactive items are removed. The UI no longer hides a five-hour value merely because the weekly value is tighter. AgentGrid reads Claude's `expiresAt` before the request and maps an expired login or usage 401 to one sanitized `/login` action, preserving any last-good windows as stale. It does not exchange refresh tokens, retry an unauthorized request, or write Claude's Keychain item.

### Grok

`GrokUsageReader` becomes an ACP adapter:

1. Spawn `~/.local/bin/grok --no-auto-update agent stdio` in the canonical terminal environment.
2. Send newline-delimited JSON-RPC 2.0 `initialize` with protocol version 1 and minimal client capabilities.
3. After the successful initialize response, send the ACP extension request with wire method `_x.ai/billing` and the required empty object `params: {}`. ACP strips the leading underscore and routes the semantic extension method `x.ai/billing`.
4. Parse `config.creditUsagePercent` and `config.currentPeriod.end` for the included weekly/monthly window. If enabled and a positive cap exists, parse on-demand used/cap as a second percentage row. Deprecated monthly fields are fallback only. Prepaid balance without a denominator is supporting detail, not a fabricated percentage quota.

The canonical Grok 1.0.5 process was probed credential-safely on 2026-08-25. `initialize` succeeded and returned the structural keys `_meta`, `agentCapabilities`, `authMethods`, and `protocolVersion`; `_x.ai/billing` with `params: {}` then succeeded and returned `config` plus `subscription_tier`. No `authenticate` request was sent. Omitting the `params` member returned JSON-RPC `-32602`, while sending unprefixed `x.ai/billing` returned `-32601`; both failures confirm the required empty params and ACP extension prefix. The probe suppressed stderr and emitted only method order, status codes, and response key names—no auth or billing values.

The production process has a 15-second end-to-end timeout, bounded stderr, cancellation that closes pipes and terminates the child, and no raw response or authentication logging. The CLI owns its cached authentication, token refresh, and credential storage. AgentGrid must not invent an `authenticate` exchange merely because initialize advertises auth methods; if a future live CLI proves authentication is required, that version's documented/observed exchange must be captured in a new fixture first. There is no direct REST or auth-file fallback; an older CLI without the billing extension produces an actionable unavailable state and the normal maintenance path updates it.

### Cursor

`CursorUsageReader` keeps its read-only, WAL-aware SQLite credential load and bounded usage-summary request. It emits distinct Cursor Models and Other Models monthly pools when the payload supplies them, including the billing-cycle end. A legacy composite plan percentage remains a single `Monthly` fallback window. Team/pooled data is used only when it is the authenticated dashboard's applicable allowance. Missing fields never become zero.

## Refresh orchestration

`CLIUsageRefreshCoordinator` is an actor and the sole scheduler. `CLIUsageModel` is a `@MainActor @Observable` presentation owner and does not sleep, watch AppKit notifications, or decide retry times.

The coordinator accepts injected clock, lifecycle event stream, network event stream, service, and jitter source. Production uses `ContinuousClock`, `NSApplication`/`NSWorkspace` notifications, and `NWPathMonitor`; tests use deterministic fakes.

Refresh triggers are:

- immediate once at app launch;
- every 60 seconds while `NSApp.isActive`/SwiftUI scene phase is active;
- immediately when AgentGrid becomes active after being inactive;
- immediately after workspace wake or screen wake;
- immediately on an `NWPathMonitor` transition from unsatisfied/requires-connection to satisfied;
- immediately for an explicit refresh-button action.

No periodic fetch starts while the app is inactive. Becoming inactive cancels only the timer, not an already-started bounded fetch. Repeated triggers during an in-flight fetch union their provider sets and produce at most one follow-up pass. A periodic tick never creates parallel provider requests.

Backoff is per provider so one broken integration does not slow the other three. Consecutive failures schedule eligibility at 60, 120, 240, 480, then 900 seconds, with production jitter of 0...10 percent. Success resets that provider's backoff. Periodic ticks skip providers not yet eligible. Manual refresh, app activation, wake, and network recovery may perform one immediate override, then return to backoff if the attempt fails. Tests inject zero jitter.

## Compact four-provider UI

The bottom rail has four equal provider columns followed by the existing refresh control. Each column contains:

- one inline provider label;
- one compact label-and-percentage item per meaningful quota window, arranged in at most two lines;
- an explicit stale/unavailable warning marker; and
- provider-level loading/unavailable text when no windows exist.

The rail is fixed at 32 points and does not drop semantic windows. Provider and window order is deterministic; dynamic window IDs remain stable. A row is one accessibility element with provider, window, remaining percentage, full localized reset date, freshness, and failure reason. Reset, last-updated, and failure detail live in tooltip and accessibility text rather than a separate visual line. The provider column is an accessibility containment group. Stale and unavailable providers show a warning icon as well as reduced emphasis. The refresh control remains a real `Button`, disabled only while a pass is in flight.

## Design twice: focus retention

### Approach A — prevent activation only at known launch sites

AgentGrid could wrap `open`, browser launches, AppleScript, and known subprocess commands to request background behavior.

Advantages:

- Prevents some steals before they happen.
- Does not need to observe global input.

Costs:

- There is no single launch boundary: five CLIs and their descendants can activate apps through shell commands, URLs, Apple events, SDKs, or automation tools.
- Wrappers change the unrestricted terminal environment and are bypassable.
- It cannot repair a steal from an already-running app.

### Approach B — app-level user-intent gate

While AgentGrid is active, a controller observes explicit switch gestures and workspace activation changes. A user gesture grants one short switch lease. If another application activates without a valid lease, AgentGrid requests activation for itself and re-keys its main window. If the lease is valid, AgentGrid disarms until the user activates AgentGrid again.

Advantages:

- Covers all child processes and external apps without mutating terminal commands.
- Separates explicit user intent from programmatic activation.
- Can be tested with a purpose-built focus-steal helper app.

Costs:

- AppKit global monitors never receive events dispatched to AgentGrid itself, so one global monitor cannot classify every switch gesture. Key-related events on the global monitor require Accessibility trust; local events and globally monitored mouse events do not have that documented requirement.
- Activation and global event notifications are asynchronous, so the controller needs a bounded decision delay and cannot rely on polling a race-prone `NSRunningApplication` property.
- Cooperative activation cannot recover from a non-yielding browser automation steal; bounded recovery therefore force-activates only after the explicit-intent decision window closes.

### Selection

Approach B is selected because it is complete at the app boundary and preserves unrestricted PTYs. Explicit-switch intent always disarms recovery; when no intent lease exists, the bounded recovery adapter uses `activateIgnoringOtherApps` because browser automation does not yield activation cooperatively.

## Focus state machine

`ApplicationFocusRetentionController` is `@MainActor` and owns this state:

- `disarmed`: AgentGrid is not active or has no visible normal window.
- `armed`: AgentGrid is active and focus retention is enabled.
- `switchLease(expiresAt:)`: an explicit user switch gesture was observed while armed.
- `recovering(targetPID:)`: a programmatic activation is being rejected.

When armed, the adapter installs both AppKit event-monitor kinds because their scopes are mutually exclusive:

- `NSEvent.addLocalMonitorForEvents` observes relevant key/flags and mouse events that AppKit dispatches to active AgentGrid and always returns the original event unchanged.
- `NSEvent.addGlobalMonitorForEvents` observes copies of mouse events dispatched to other applications. When Accessibility trust is present, its mask may also include key-related events dispatched outside AgentGrid; without trust, the adapter does not claim those events are observable.

A qualifying click, Command-Tab/Shift-Command-Tab, Command-Space followed by app activation, or the explicit `Allow Next App Switch` command creates a one-use lease for 1.5 seconds. The local monitor classifies switch keys delivered while AgentGrid is active; the Accessibility-gated global key path covers qualifying key events the system dispatches elsewhere. `NSWorkspace.didActivateApplicationNotification` supplies the activated application. The controller defers its decision for 120 milliseconds so an asynchronous global input copy can arrive.

If a valid lease exists, the controller consumes it and enters `disarmed`; the chosen app keeps focus indefinitely. If not, it calls modern `NSApp.activate()`, then `makeKeyAndOrderFront` on AgentGrid's existing main window on the next main-run-loop turn. While AgentGrid remains inactive, the controller retries every 250 milliseconds for at most five seconds. Further notifications coalesce into that recovery sequence, and the hard deadline prevents an unbounded focus war. A click, Command-Tab, disable, stop, or successful activation cancels recovery immediately. When AgentGrid becomes active, it re-arms. A menu command to disable/enable focus retention and the one-shot switch command provide an escape for gestures AppKit cannot classify.

The controller never captures, stores, or logs keystrokes. It examines only event type/modifier/key code needed to recognize switching and immediately discards the event. The global monitor is observation-only; the local monitor also returns every event unchanged. Both monitors are removed when retention stops.

## Focus validation seam

A test-only `FocusStealFixture` macOS app target has a distinct bundle identifier and two modes:

- `--programmatic`: launches and immediately calls its own activation API without input;
- normal: shows one button so a tester can click it as an explicit switch.

Unit tests use fake event/activation clients and a test clock to cover leases, coalescing, disarming, recovery, and bounded retry. The helper supports the final manual matrix:

- programmatic helper activation returns focus to AgentGrid;
- clicking the helper leaves focus on the helper;
- Command-Tab away leaves focus on the selected app;
- returning to AgentGrid re-arms protection;
- a programmatic steal during terminal typing does not redirect subsequent keystrokes;
- the one-shot menu command works when Accessibility trust is absent.

No automated assertion substitutes for the final manual typing/focus inspection.

## Durable permission identity

### Signing and install contract

The Release configuration uses Manual signing with exact identity `Apple Development: <maintainer email> (<label>)` and certificate team `<team ID>`, forbids ad-hoc fallback, keeps bundle ID `com.thechosenvictor.AgentGrid`, keeps hardened runtime on, and keeps App Sandbox off. Debug tests may use Xcode's normal host signing, but a shippable local Release must report that exact Apple Development authority and the certificate-derived team identifier.

Every installed update replaces the same path, `~/Applications/AgentGrid.app`, without editing the signed bundle after build. Two independently built Release bundles must have the same `codesign -d -r-` designated requirement even when their build number differs. macOS uses that designated requirement to recognize an update as the same program.

The current ad-hoc build cannot be the same identity as the first signed build. One final consent migration may therefore be required when 1.3.4 first replaces it. After that migration, the fixed identifier, team, designated requirement, and install path are release gates intended to preserve grants across updates.

### Protected capabilities

- Accessibility is required only for key-related events on the global event monitor. It is not required for the local monitor while AgentGrid is active or for the documented global mouse-event path. AgentGrid calls `AXIsProcessTrustedWithOptions` with prompting disabled during ordinary launch and activation preflight, never automatically re-prompts, and enables the global key mask only when trusted. If untrusted, it presents a non-modal readiness warning and an explicit user action that can request/open Accessibility settings once; local key intent, global mouse intent, and `Allow Next App Switch` remain available.
- Full Disk Access and Files & Folders access can only be granted by the user on an unmanaged Mac. There is no supported general Full Disk Access status API. AgentGrid tests the actual file operation it needs and reports `EPERM`/`EACCES` with a route to the relevant settings. It never reads or writes TCC databases.
- The one-time installed-app checklist asks the user to grant the fixed AgentGrid bundle Accessibility and Full Disk Access for unrestricted terminal descendants, then validates real protected operations through a terminal pane. It does not claim the app granted itself access.
- No App Sandbox entitlement is added. No camera, microphone, location, contacts, calendars, Bluetooth, screen capture, or Apple Events usage description/entitlement is added because AgentGrid itself does not use those resources. Provider credentials remain owned by their CLIs/apps.
- Permission readiness does not destroy existing terminal sessions. Without Accessibility, focus retention retains local AgentGrid-event classification, global mouse intent, and the explicit one-shot escape, and accurately reports that key events dispatched outside AgentGrid cannot be globally classified.

## Ownership and module boundaries

| Owner | Responsibility |
| --- | --- |
| `ProviderUsageSnapshot.swift` | Stable provider/window domain, freshness, reset metadata |
| Provider reader/parser files | Translate one provider payload into semantic observations |
| `CLIUsageReading.swift` | Concurrent reads and last-good per-window merge only |
| `CLIUsageRefreshCoordinator.swift` | Lifecycle triggers, 60-second cadence, per-provider backoff, coalescing |
| `UsageLifecycleMonitor.swift` | AppKit/Network notification adapters only |
| `CLIUsageModel.swift` | Main-actor observable projection and commands |
| `CLIUsageBar.swift` / `CLIUsageSegment.swift` | Four-column, multi-row rendering only |
| `ApplicationFocusRetentionController.swift` | Focus intent state machine and activation recovery |
| `FocusIntentMonitor.swift` | AppKit event/activation adapters only |
| `PermissionReadiness.swift` | Supported preflight/reporting, never grant mutation |
| `AgentGridApp.swift` / `WindowMaximizer.swift` | Composition and main-window reference only |

`AgentGridWorkspaceView` does not own service lifetime. App-level owners are initialized once with `@State`, passed down, and stopped on application teardown. No business logic moves into SwiftUI views, and AppKit bridges remain narrowly scoped to capabilities SwiftUI does not expose.

## Security and privacy

- Provider fetches are concurrent, cancellable, independently bounded, and never log raw authenticated payloads.
- Grok credentials are never parsed or copied by AgentGrid; the authenticated CLI owns them.
- Claude and Cursor credential reads remain ephemeral and local until those providers offer equally capable authenticated CLI protocols.
- Global event monitoring retains no event content and never modifies event delivery.
- Focus recovery never terminates, hides, or manipulates the other app; it only requests AgentGrid activation.
- Permission errors contain capability and remediation, never sensitive path contents or credential values.
- No quota history, event history, focus-target history, or permission database is persisted.

## Validation and release gates

- Parser tests cover all meaningful windows, semantic IDs, resets, dynamic additions, explicit null/removal, malformed individual windows, and clamps.
- Service tests prove per-window stale merge, provider failure isolation, explicit removal, and stable order.
- Coordinator tests use a fake clock to prove 60-second foreground polling, no background polling, lifecycle/network recovery, backoff, manual override, cancellation, and one pending coalesced pass.
- Focus tests prove manual leases and programmatic rejection; the helper-app/manual matrix proves real macOS behavior.
- Permission tests prove quiet preflight, explicit prompt routing, no repeated prompt request, actual-operation error reporting, and no TCC database dependency.
- Signing validation proves a valid deep signature, team `<team ID>`, stable designated requirement across two distinct Release builds, hardened runtime on, sandbox off, and a byte-identical installed bundle at the fixed path. A regression explicitly rejects treating the authority label suffix `<label>` as TeamIdentifier. `spctl` output is recorded, but Apple Development signing is not misrepresented as Developer ID/notarized distribution.
- Generated-project drift, focused tests, the complete test suite with the live-network marker absent, Debug and Release builds, secret scans, manual visual/accessibility inspection, installed-app runtime inspection, and two-launch permission/focus checks must pass.
- Ship the corrected candidate as 1.3.4 build 9, monotonically superseding the installed build 8. Update README, context map, third-party notice only if copied implementation requires it, project version, generated project, install documentation, and the authoritative owner tracker. App Store submission remains outside this repair.

## Official references

- [OpenAI: Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540)
- [OpenAI Codex app-server README: `account/rateLimits/read`](https://github.com/openai/codex/tree/main/codex-rs/app-server)
- [Anthropic: Manage usage credits for paid Claude plans](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans)
- [Anthropic: Use Claude Code with your Pro or Max plan](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan)
- [Anthropic: What is the Pro plan?](https://support.claude.com/en/articles/8325606-what-is-the-pro-plan)
- [Cursor: Models & Pricing](https://cursor.com/docs/models-and-pricing)
- [xAI: Grok Usage & Limits](https://docs.x.ai/grok/faq#usage--limits)
- [xAI: Grok Build headless scripting and ACP](https://docs.x.ai/build/cli/headless-scripting)
- [xAI Grok Build: `x.ai/billing` extension source](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs)
- [Apple: Workspace application activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Apple: Global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))
- [Apple: Cooperative application activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)
- [Apple: `AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Apple Code Signing Guide: Shipping and Updating Your Product](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html#//apple_ref/doc/uid/TP40005929-CH4-SW14)
- [Apple: Privacy Preferences Policy Control payload](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-settings-dep38df53c2a/web)
