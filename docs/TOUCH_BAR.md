# Touch Bar implementation

The Touch Bar is an optional presentation layer. The menu-bar usage display
does not depend on Touch Bar hardware or on the private system-modal path.

## Layouts

The app keeps one reusable Touch Bar controller and switches its content
without destroying the entire bar:

- **Compact numbers**: official service icon, status light, five-hour value,
  and period value.
- **Dual quota bars**: official service icon, status light, two fixed-height
  quota bars, percentages, and reset times.

The dual layout uses a shared 60–110 pt bar-width constraint for Codex and Kimi.
The status light uses a shared size preference with a 6–16.5 pt compact range
and a 6–25 pt dual-bar range. A setting change updates constraints in place,
which avoids a visible teardown/rebuild flash.

## Status light

`WorkStatusLightView` renders the state color, a soft glow, and the animation:

- green breathing for active work;
- slow yellow pulse while waiting for a user action;
- dim white for idle;
- red for an explicit failure;
- hollow gray for unknown;
- a three-second rainbow sweep after completion.

Animation is disabled when macOS requests reduced motion and is stopped while
the Touch Bar is unavailable or asleep.

## Service activation

Touch Bar service icons use the installed Codex and Kimi Code application icons.
`AppLauncher` calls `NSWorkspace.openApplication` with activation enabled and
then explicitly unhides and activates all windows. This makes a minimized
Electron window return to the foreground without forcing full-screen mode.

## IP-region status ring

`IPRegionIndicator` is an optional 26 pt circular component at the left side of
the app region. It converts the two-letter region code to Unicode regional
indicator scalars; `Apple Color Emoji` renders the result as a native macOS
flag. A Core Animation ring indicates online, checking, degraded, offline, or
unknown network state. The component is removed entirely when its preference is
off.

## Public and system-modal paths

For ordinary app-owned Touch Bar content, the controller uses public
`NSTouchBar` APIs and assigns the bar while display is enabled.

To keep the app's bar visible while Codex owns keyboard focus, the app optionally
uses these undocumented AppKit selectors after runtime availability checks:

```text
presentSystemModalTouchBar:placement:systemTrayItemIdentifier:
dismissSystemModalTouchBar:
```

The private path is enabled only when Touch Bar display, persistent display, and
the required runtime selectors are all available. A failed or missing selector
does not affect menu-bar usage. This behavior is not suitable for Mac App Store
distribution and may require adaptation after a macOS update.

## Recovery and system controls

The controller reuses one system-modal session and avoids killing or restarting
Control Strip during a manual reconnect. It re-registers the refresh anchor
after modal dismissal or a Control Strip restart. The app's own Touch Bar
content does not add a left-side close button or a duplicate system-control
grid; any remaining system controls are owned by macOS.

macOS may dim the Touch Bar after a period without keyboard or trackpad input.
The app does not override that power-management behavior. Hardware-level black
screens remain outside the scope of this utility.
