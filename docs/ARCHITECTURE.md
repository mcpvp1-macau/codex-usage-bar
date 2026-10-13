# Architecture

Codex Kimi Usage Bar is a single native Swift executable. AppKit owns the
process lifetime, status item, menu, application activation, and Touch Bar
integration. SwiftUI supplies the settings scene and the expanded usage view.
There are no third-party Swift packages and no companion daemon.

## High-level data flow

```text
                         ┌────────────────────────┐
                         │      UsageStore        │
                         │ state, preferences,    │
                         │ refresh scheduling     │
                         └──────────┬─────────────┘
                                    │
       ┌────────────────────────────┼────────────────────────────┐
       │                            │                            │
       ▼                            ▼                            ▼
┌───────────────┐          ┌────────────────┐          ┌────────────────┐
│ Codex client  │          │ Kimi Code      │          │ Local status   │
│ app-server    │          │ usage endpoint │          │ and IP region  │
└──────┬────────┘          └───────┬────────┘          └───────┬────────┘
       │ JSON-RPC                    │ HTTPS                    │ HTTPS/logs
       └──────────────┬─────────────┴──────────────┬───────────┘
                      ▼                            ▼
              UsageSnapshot / KimiUsageSnapshot  activity + region
                      │                            │
       ┌──────────────┴───────────────┐            │
       ▼                              ▼            ▼
  menu-bar status item          SwiftUI menu   Touch Bar controller
```

## Components

### `UsageStore`

`UsageStore` is the observable state boundary. It owns Codex and Kimi snapshots,
errors, refresh timers, quota-reset scheduling, launch-at-login preferences,
Touch Bar preferences, and the IP-region refresh loop. Published changes update
the status item, the SwiftUI popover, and the Touch Bar on the main actor.

### Codex client

`CodexUsageClient` locates a local `codex` executable and launches:

```text
codex app-server --stdio
```

It sends newline-delimited JSON-RPC and requests the read-only
`account/rateLimits/read` method. The response is normalized into rate windows,
reset dates, plan information, credits, and reset counts. Timeouts terminate
only the child process; they do not terminate the menu-bar app.

### Kimi Code client

`KimiUsageClient` selects the official Kimi Code region endpoint from the local
region marker. It reads an optional API Key from the macOS Keychain, otherwise
uses the local Kimi Code CLI credential. It parses current and legacy usage
window shapes into a common `KimiUsageSnapshot`.

When a CLI access token is expired, the client locks the CLI credential file,
refreshes the OAuth token, writes it atomically, and releases the lock. This
prevents concurrent refreshes from the app and the CLI from corrupting the
credential file.

### Activity monitor

`WorkActivityMonitor` reads only local lifecycle markers:

- Codex task logs are checked incrementally and parsed for start, completion,
  interruption, waiting, and failure markers.
- Kimi Code activity is derived from `event.session.work_changed` state events.
- Multiple sessions are merged with the priority waiting > working > recent
  completion.

Prompt text, conversation bodies, and tool payloads are not extracted. If a
session cannot be inspected reliably, its state is reported as unknown.

### Menu bar and settings

`AppDelegate` creates one `NSStatusItem` and one custom `NSMenu` whose content is
an `NSHostingView<UsagePopover>`. The gear action immediately cancels menu
tracking and sends the standard `showSettingsWindow:` action. The settings
content is provided by the single SwiftUI `Settings` scene, so there is no
second manually-created settings window to compete with it.

The settings action does not wait for `menuDidClose`; this is intentional. On
some macOS releases a menu cancelled from an embedded SwiftUI button does not
deliver the delegate callback, and waiting for it would make the settings page
appear to do nothing.

### Touch Bar

`UsageTouchBarController` keeps a reusable Touch Bar tree for Codex and Kimi.
`TouchBarLayout.swift` contains the compact-number and dual-quota-bar layouts,
the shared quota palette, and the configurable bar-width constraints.
`WorkStatusLightView` draws the status lamp and its animations. Icons use the
installed applications' own bundle icons, and `AppLauncher` restores and
activates minimized windows.

`IPRegionIndicator` draws the optional circular region component. It converts a
two-letter region code to Unicode regional-indicator scalars, which macOS
renders with Apple Color Emoji, and uses a Core Animation ring for online,
checking, degraded, offline, and unknown states.

Normal application Touch Bar content uses public `NSTouchBar` APIs. Persistent
display while another app owns keyboard focus is isolated behind
`TouchBarSystemModal`, which checks undocumented AppKit selectors at runtime.
If those selectors are unavailable, the menu bar remains fully functional and
the app falls back to the public path.

## Preferences and persistence

User-facing preferences use `UserDefaults` and are clamped at load time so
values from older builds cannot exceed the current UI ranges. Kimi API keys use
`kSecClassGenericPassword` with device-only accessibility. No usage snapshot is
written to disk.

## Build and release

`build-app.sh` builds each requested architecture with SwiftPM, creates the
asset catalog, assembles the `.app` bundle, and signs it. `build-local.sh` is a
local Apple Silicon fallback for environments where the installed SwiftPM and
SDK versions do not agree. `scripts/release.sh` performs bundle checks and
creates the versioned archive and checksum.
