# Privacy

Codex Kimi Usage Bar is a local-first utility. It contains no advertising,
telemetry, crash-reporting SDK, or third-party analytics service.

## Data read from the computer

### Codex

The app locates and starts the locally installed:

```text
codex app-server --stdio
```

It sends the read-only `account/rateLimits/read` request. The response may
contain the account plan, remaining rate-limit percentages, reset timestamps,
credit balance, and reset count. The app does not request conversation history,
prompts, cookies, or access tokens.

### Kimi Code

Kimi usage is read from the official Kimi Code coding-usage endpoint. The app
uses an API Key only when the user has explicitly saved one in the app's
settings. Otherwise it reads the local Kimi Code CLI credential that the Kimi
client already manages. An expired access token may be refreshed through the
CLI's OAuth refresh protocol under the CLI credential lock.

The API Key is stored in the macOS Keychain as a generic password with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is never printed in the
menu, log, self-test output, or Git repository.

### Activity state

The status lights use local lifecycle markers from Codex task logs and Kimi
`event.session.work_changed` events. The parser does not extract prompts,
conversation text, tool arguments, or response bodies. When a local session is
not accessible or does not expose a reliable marker, the app reports unknown.

### IP-region ring

When enabled, the app makes a small HTTPS request to a region-check service.
Only the returned two-letter region code and a coarse network state are kept in
memory for the ring and flag display. The exact public IP is not shown,
stored, logged, or sent to another service by this app.

The region can change when a VPN or proxy changes its network exit. Turning off
the IP-region setting stops the component and its refresh loop.

## Local storage

`UserDefaults` stores only display and behavior preferences, including:

- menu-bar icon size and text size;
- refresh interval;
- Touch Bar enablement, persistence, layout, bar width, and light size;
- IP-region ring visibility;
- launch-at-login preference.

Usage snapshots, activity logs, exact IP addresses, and prompts are not saved
by the app.

Kimi network requests use an ephemeral `URLSession` with no persistent URL
cache and no cookie storage. Codex communication is performed through the
local app-server process and follows the normal signed-in Codex client path.

## Removing local data

Quit the app, disable launch at login, remove the application, and remove its
preferences if desired:

```bash
defaults delete com.local.codexkimiusagebar
```

If an API Key was saved, remove it from the app's Kimi Code settings before
uninstalling, or delete the corresponding Keychain item through Keychain
Access. The app does not delete Kimi Code's own CLI credentials.
