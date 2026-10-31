<div align="center">

<img src="Resources/Artwork/AppIcon.svg" width="112" alt="Mouse Master icon">

# Mouse Master for Mac

**Everything your Logitech mouse can do, without Logi Options+.**

A native macOS app (Swift, SwiftUI, IOKit) that talks to Logitech mice over HID++ directly:
remap every button, hold and move for gestures, glide with smooth scrolling, tune
SmartShift and the thumb wheel, and give every app its own setup, all in a background
agent that uses about 10 MB of memory and no CPU while idle.

</div>

## Why

Logi Options+ is an Electron app with several always-running helpers that together use
hundreds of megabytes of memory, need an account, phone home, and are slow to apply
settings when the mouse wakes up. Mouse Master does the same job natively:

| | Mouse Master | Logi Options+ |
| --- | --- | --- |
| Memory while idle | ~10 MB, one process | 300+ MB, several processes |
| CPU while idle | 0 % (no timers, no polling) | background activity |
| Settings after the mouse wakes up | ~0.7 s (cached device data) | seconds |
| Account, telemetry, updater | none | yes |
| Smooth scrolling per mouse, trackpad untouched | yes | yes |
| Per-app profiles, gestures, thumb wheel actions | yes | yes |

## Features

- **Every button, any action.** Mission Control, App Exposé, Spaces, Show Desktop, Spotlight,
  Notification Center, screenshots, window tiling, media keys, brightness, tabs, zoom, copy and
  paste, keyboard shortcuts (recorded with your keyboard layout, held while the button is held),
  mouse buttons, apps, files, URLs, Shortcuts, shell commands, typed text, macros, pointer speed,
  Easy-Switch. Back and Forward work everywhere: ⌘[ / ⌘] where an app expects it (Safari,
  Finder…), mouse buttons 4/5 elsewhere.
- **Gestures** on every button that reports motion (on the MX Master: gesture, middle, back,
  forward, mode shift): up/down/left/right/click with presets, repeat while moving, a release
  trigger, **pan** (move to scroll in any direction) and smooth **zoom** modes.
- **Smooth scrolling.** The wheel is read at full resolution (15 steps per notch on the
  MX Master 3S) and turned into continuous, trackpad-like scrolling with adjustable speed and
  acceleration. Scroll direction is set per mouse, independent from the trackpad.
- **Thumb wheel:** smooth horizontal scrolling, smooth zoom (a real trackpad pinch, around the
  pointer), volume, brightness, tabs, Spaces,
  undo/redo, tracks or any two actions; tap action on touch-sensitive wheels.
- **Pointer speed** (DPI) with presets and a cycle action, **precision mode** while a button is
  held, **SmartShift** and ratchet/free spin, MX Master 4 torque and haptics.
- **Application profiles** that switch instantly with the frontmost app.
- **Live:** pressed buttons light up in the app, gestures flash the direction they triggered.
- **Menu bar:** battery at a glance, pointer speed, smooth scrolling, SmartShift, Easy-Switch,
  pause. A small on-screen display for pointer speed, wheel mode and battery.
- **Bluetooth, Logi Bolt, Unifying and Lightspeed receivers.** Every control is given back its
  native function when Mouse Master pauses or quits, and nothing is diverted until macOS allows
  Mouse Master to act, so the mouse never stops working.

Tested with an MX Master 3S over Bluetooth. Other HID++ 2.0 mice (MX Master 2S/3/4,
MX Anywhere 2S/3/3S, MX Vertical, Lift, M720…) are expected to work: features are discovered
from the device.

## Install

Requires macOS 14 or later and Xcode (or the Swift toolchain).

```sh
git clone <this repository> mouse-master-mac
cd mouse-master-mac
scripts/install.sh
```

The script builds a release, installs `/Applications/Mouse Master.app`, registers the
background agent (it starts at login and is restarted if it ever crashes) and opens the app,
which walks you through the two permissions macOS asks for:

- **Input Monitoring:** to talk to the mouse over HID++,
- **Accessibility:** to press keys, click and scroll.

`scripts/install.sh --uninstall` removes the app and the agent; settings stay in
`~/Library/Application Support/Mouse Master`.

> [!NOTE]
> The app is signed ad hoc by default (no developer certificate needed). macOS ties the two
> permissions to the agent's signature, which stays the same as long as the agent's sources do
> not change. If an update changes it, macOS may ask again: switch Mouse Master off and on in
> System Settings › Privacy & Security. Set `CODESIGN_IDENTITY` to sign with a (valid,
> non-revoked) certificate instead.

## Command line

`mmctl` talks to the agent (installed into `/opt/homebrew/bin` or `/usr/local/bin` when possible,
otherwise in `Mouse Master.app/Contents/Helpers`):

```console
$ mmctl status
● MX Master 3S  [b034-5C8F7AF8]  Bluetooth  battery 80%
  1000 DPI · wheel ratchet · SmartShift 25 · smooth scrolling · thumb wheel handled
  …
$ mmctl set dpi=1600 scrollSpeed=1.3 scrollDirection=standard
$ mmctl bind middle mission-control
$ mmctl bind forward '{"type":"keys","keyCode":17,"modifiers":["command","shift"]}'
$ mmctl bind thumbwheel volume
$ mmctl watch                     # live button presses and gestures
$ mmctl actions                   # every built-in action
```

Feel of scrolling, without a rebuild:

```sh
defaults write com.burakgon.MouseMaster.Agent ScrollSmoothing -float 0.065      # seconds
defaults write com.burakgon.MouseMaster.Agent ScrollPointsPerNotch -float 42
defaults write com.burakgon.MouseMaster.Agent ThumbwheelPointsPerTurn -float 520
```

## How it works

```
 Logitech mouse ──HID++ (IOKit)──▶ MouseMasterAgent ──CGEvent──▶ macOS
 Bluetooth / receiver               │  ▲    (keys, clicks, continuous scrolling,
                                    │  │     system hot keys, media keys)
          Unix socket, JSON lines   ▼  │
                         Mouse Master.app (SwiftUI), mmctl
```

- **`Sources/HIDPP`**: HID++ 1.0/2.0 over IOKit: report descriptors, one request in flight per
  device with reply matching, feature table, the features (battery, DPI, SmartShift, hi-res
  wheel, thumb wheel, reprogrammable controls, Easy-Switch, haptics) and receivers.
- **`Sources/MouseMasterAgent`**: the background agent (`LSUIElement`, launchd via
  `SMAppService`). One controller per device diverts only the controls that have an action, reads
  raw motion for gestures, diverts the wheels for smooth scrolling, and applies the configuration
  again whenever the device reconnects or wakes. Static device data is cached, so a waking mouse
  is ready in a few requests. Everything runs on the main run loop; there are no timers while
  idle.
- **`Sources/MouseMasterKit`**: configuration, the action model and catalog, device snapshots,
  the IPC protocol and the pure engines (gestures, thumb wheel, wheel acceleration, scroll
  animation), with unit tests.
- **`Sources/MouseMaster`**: the settings app. It only runs while its window is open.

Mission Control, App Exposé, Show Desktop, Spaces and other system shortcuts are triggered
through the user's own symbolic hot keys (temporarily enabled if they are turned off), so they
work regardless of how the keyboard shortcuts are configured.

## Development

```sh
swift build                       # debug build of everything
swift test                        # protocol, engines, configuration
.build/debug/MouseMasterAgent -v  # run the agent in a terminal (uses the terminal's permissions)
scripts/build.sh                  # build/Mouse Master.app
```

Run only one agent at a time. Stop the installed one with
`launchctl kill TERM gui/$(id -u)/com.burakgon.MouseMaster.Agent`.

## Acknowledgements

The HID++ knowledge comes from [Mouse Master for Linux](https://github.com/burakgon/mouse-master-linux),
which in turn builds on [Solaar](https://github.com/pwr-Solaar/Solaar),
[logiops](https://github.com/PixlOne/logiops) and Logitech's published HID++ documentation.

## License

GPL-3.0-or-later. Logitech, Logi, MX Master, MX Anywhere, Bolt, Unifying, Lightspeed,
Easy-Switch and SmartShift are trademarks of Logitech. Mouse Master is an independent project
and is not affiliated with, endorsed by, or sponsored by Logitech.
