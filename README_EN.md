<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Codex Kimi Usage Bar icon">
</p>

<h1 align="center">Codex Kimi Usage Bar</h1>

<p align="center">A native macOS menu-bar and Touch Bar utility for Codex and Kimi Code usage.</p>

<p align="center"><a href="README.md">中文</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="docs/ARCHITECTURE.md">Architecture</a> · <a href="docs/PRIVACY.md">Privacy</a></p>

> [!IMPORTANT]
> This is an unofficial personal-use community project. It is not affiliated with, sponsored by, or endorsed by OpenAI, Kimi, or Moonshot. Local Codex, Kimi Code, and persistent Touch Bar interfaces may change without notice.

## Overview

Codex Kimi Usage Bar brings Codex and Kimi Code usage into one lightweight native macOS utility. It shows five-hour and service-provided period limits, reset times, activity lights, and an optional network-region ring without asking users to copy browser cookies or conversation data.

The app is a single local process with no third-party Swift packages and no background daemon.

## Features

- Menu-bar display with the official local Codex and Kimi Code app icons, five-hour remaining percentage, reset time, and activity light.
- Native expanded menu with progress bars, period limits, credits or reset counts when returned by the service, manual refresh, service links, settings, and quit.
- Two Touch Bar layouts: compact numbers or dual quota bars. Dual bars support a shared 60–110 pt width; status lights support 6–16.5 pt in compact mode and 6–25 pt in dual-bar mode.
- Touch Bar service icons restore minimized windows and bring Codex or Kimi Code to the foreground without forcing full screen.
- Activity lights for working, waiting, idle, failed, and unknown states, including a soft three-second rainbow completion animation.
- Optional IP-region status ring with a native macOS flag emoji in the center and a colored network ring. The exact public IP is not displayed or persisted.
- Launch at login, configurable refresh interval, IP-ring switch, layout selector, and Touch Bar recovery action.
- No third-party runtime dependencies, telemetry, advertising, or analytics SDK.

## Technology and implementation

- Swift 5.10 and Swift Package Manager on macOS 14+.
- AppKit for `NSStatusItem`, `NSMenu`, `NSWindow`, `NSTouchBar`, and foreground application activation.
- SwiftUI embedded with `NSHostingView` for the settings page and expanded usage menu.
- Combine for state propagation and redraw scheduling.
- Foundation and ephemeral `URLSession` for local process I/O, Kimi Code usage, and region checks.
- Security Keychain for an optional user-provided Kimi Code API key.
- ServiceManagement for launch-at-login registration.
- QuartzCore for quota bars, the network ring, and activity animations.
- Runtime probing of undocumented AppKit system-modal Touch Bar selectors, with a public-API fallback when unavailable.

### Data sources

Codex usage is read from the locally installed `codex app-server --stdio` process through the read-only `account/rateLimits/read` JSON-RPC request. Kimi Code usage is read from the official coding usage endpoint using a Keychain API key or the local Kimi Code CLI credential. Expired CLI tokens are refreshed under the CLI credential lock to avoid concurrent writes.

Activity monitoring extracts lifecycle markers from locally accessible Codex logs and Kimi `event.session.work_changed` events. It never reads or stores prompt content.

## Privacy

- Codex cookies, access tokens, and conversation content are not stored by this app.
- Kimi API keys are stored only in the macOS Keychain; CLI credentials remain managed by Kimi Code.
- The region ring keeps only a two-letter region code for the displayed flag; it does not persist the exact public IP.
- Preferences are stored in `UserDefaults`.
- Kimi and region checks use HTTPS; the app uses an ephemeral session without persistent cookies or URL cache.

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Requirements

- macOS 14.0 or later.
- A signed-in Codex desktop client.
- A signed-in Kimi Code client or a valid Kimi Code API key for Kimi usage.
- A Touch Bar MacBook Pro for Touch Bar features; the menu bar works on other Macs.

## Build

```bash
git clone https://github.com/adityajha2005/codex-usage-bar.git
cd codex-usage-bar
./build-app.sh dist
open "dist/Codex Kimi Usage Bar.app"
```

For the local Apple Silicon toolchain:

```bash
./build-local.sh /tmp/codex-kimi-build
"/tmp/codex-kimi-build/Codex Kimi Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
```

The default release build is universal (`arm64` and `x86_64`). The bundle is ad-hoc signed unless a Developer ID identity is supplied.

## Limitations

The Codex app-server and Kimi Code usage interfaces are client-facing implementation details rather than stable third-party SDKs. Persistent Touch Bar presentation uses undocumented AppKit selectors and is not suitable for Mac App Store distribution. Hardware-level Touch Bar black screens, automatic dimming, and sleep behavior remain controlled by macOS and the hardware.

## License

Code and original project assets are available under the [MIT License](LICENSE). See [NOTICE.md](NOTICE.md) for the unofficial-project and trademark notice.
